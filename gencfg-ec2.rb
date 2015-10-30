#!/usr/bin/ruby

require 'aws-sdk-core'
require 'aws-sdk-resources'
require 'json'
require 'jason'
require 'fileutils'

# Hack to see if a hash contains the values in another hash..
# via http://grosser.it/2011/02/01/ruby-hashcontainother/
class Hash
  def contain?(other)
    self.merge(other) == self
  end
end

# First off, create an output directory if it doesn't already exist..
FileUtils::mkdir 'output' unless File.directory?('output')

# Load credentials from a credential-specific config file
$creds = JSON.load(File.read('creds.json'))
Aws.config[:credentials] = Aws::Credentials.new($creds['awsCredentials']['accessKeyId'], $creds['awsCredentials']['secretAccessKey'])
$awsaccountnumber = $creds['awsCredentials']['accountNumber']

# Load the rest of the configuration from a standard config file
config = JSON.load(File.read('config.json'))

awsregions = config['regions']
$outputmetrics = config['outputmetrics']
$skipinstances = config['skipinstances']
$dimensionname = config['dimensionname']
$matchtags = config['matchtags']['EC2'] unless config['matchtags'].nil?

# Use pretty JSON output format for readability..
Jason.output_format = :pretty

# Output config file for EC2 for a given region
def generateEC2Config(awsregion)

  # Define two lists of nodes to generate config for - basic (standard) monitoring and detailed monitoring..
  ec2instances = Hash.new
  ec2instances["detailed"] = Array.new
  ec2instances["basic"] = Array.new

  # ...and ditto for standard vs PIOPS EBS volumes
  ebsvolumes = Hash.new
  ebsvolumes["basic"] = Array.new
  ebsvolumes["detailed"] = Array.new

  Aws.config.update({
	  region: "#{awsregion}",
  })

  ec2 = Aws::EC2::Client.new(region: awsregion)

  # Only filters specified here should be to get rid of cruft we don't want to see at all (non-running-machines/etc) - instances
  # to include get parsed below using tags specified in the config file.
  ec2.describe_instances({ filters: [ { name: "instance-state-name", values: ["running"] } ] } ).each do |reservations|
    reservations.reservations.each do |reservation|
      reservation.instances.each do |instance|
        @instanceid = instance.instance_id

        # Populate the ec2instance hash, which will contain all the info about the ec2 instance itself.
        ec2instance = Hash.new
        ec2instance['id'] = "#@instanceid"
        ec2instance['detailedmonitoring'] = instance.monitoring.state
        ec2instance["tags"] = Hash.new
        instance.tags.each do |tag|
          ec2instance["tags"]["#{tag.key}"]  = "#{tag.value}"
        end
        ec2instance["name"] = "#{ec2instance['tags']['Name']}"

        # Determine if this instance will be included in our list to generate configs for..    
    
        # Check if this instance matches our 'skipinstances' list; if so, move on.
        if $skipinstances["EC2"].include? "#{ec2instance['name']}"
          puts "Skipping config for: #{ec2instance['name']} (on skipinstances list)"
          next
        end
    
        # If matchtags is defined, validated that this instance matches the tags we've defined - include it if so,
        # otherwise skip it.
        unless $matchtags.nil?
          # Default to excluding the instance; we'll set this to true if the instance matches one or more of the sets of tags.
          includeinstance=false

          $matchtags.each do |matchtag|
            includeinstance=true if ec2instance["tags"].contain?( matchtag )
          end

          if (includeinstance == false)
            puts "Skipping config for: #{ec2instance['name']} (matchtags doesn't include a tag for it)"
            next
          end
        end

        if ["enabled","pending"].include? ec2instance["detailedmonitoring"]
          ec2instances["basic"].push(ec2instance)
        elsif ["disabled","disabling"].include? ec2instance["detailedmonitoring"]
          ec2instances["detailed"].push(ec2instance)
        else
          abort("Instance #{ec2instance['tags']['Name']} (id #{ec2instance["id"]}) has an invalid field for detailed monitoring: #{ec2instance["detailedmonitoring"]}")
        end

        # Populate our EBS volumes into the 'EBS' hash.. include our instance
        # TODO: do one lookup for all volumes somehow.. this is slow!
        ebsvolume = Hash.new
        instance.block_device_mappings.each do |block_dev|
          next if block_dev.ebs.status != "attached"
          ebsvolume['id'] = block_dev.ebs.volume_id
          ebsvolume['ec2_id'] = "#@instanceid"

          # maybe these should be ec2_name and ec2_blockdev.. but this is probably what we'll refer to it as?
          ebsvolume['name'] = ec2instance['tags']['Name']
          ebsvolume['blockdev'] = block_dev.device_name

          ec2.describe_volumes({ volume_ids: ["#{block_dev.ebs.volume_id}"] }).each do |volumes|
            volumes.volumes.each do |volume| # There should only be one..
              ebsvolume['type'] = volume.volume_type
              ebsvolume['iops'] = volume.iops
              ebsvolume['size'] = volume.size
              ebsvolume["tags"] = Hash.new
              volume.tags.each do |tag|
                ebsvolume["tags"]["#{tag.key}"]  = "#{tag.value}"
              end
            end
          end 
        end
        
        # Logic for which EBS pool to push this into should go here.. 
        if ["io1"].include? ebsvolume["type"]
          ebsvolumes["detailed"].push(ebsvolume)
        elsif ["standard","gp2"].include? ebsvolume["type"]
          ebsvolumes["basic"].push(ebsvolume)
        else
          abort("Volume #{ebsvolume['tags']['Name']} (id #{ebsvolume["id"]}) has an invalid field for type: #{ebsvolume["type"]}")
        end
      end
    end
  end

  # Build JSON for 1 minute and 5 minute intervals
  buildjson(awsregion,ec2instances["basic"],"EC2","detailed",60)
  buildjson(awsregion,ec2instances["detailed"],"EC2","basic",300)

  # Build JSON for Standard and PIOPS EBS disk (5m and 1m intervals)
  buildjson(awsregion,ebsvolumes["basic"],"EBS","basic",300)
  buildjson(awsregion,ebsvolumes["detailed"],"EBS","detailed",60)

end

def buildjson(awsregion,instances,awsnamespace,monitoring,period)
  # TODO - figure out how to better namespace output to Carbon, so that we can have separate storage aggregations for 1m vs 5m
  $json_in = <<-EOS
{
  "awsCredentials": {
    "accessKeyId": "#{$creds['awsCredentials']['accessKeyId']}",
    "secretAccessKey": "#{$creds['awsCredentials']['secretAccessKey']}",
    "region": "#{awsregion}",
  },  
  "metricsConfig": {
    "metrics": [
EOS

  instances.each do |instance|
    puts "Generating config for: #{instance['name']} (id #{instance['id']})"

    if awsnamespace == "EBS"
      outputalias = "#{monitoring}.#{instance["name"]}.#{instance["blockdev"].gsub('/dev/','')}"
    else
      outputalias = "#{monitoring}.#{instance["name"]}"
    end

    dimensionname = $dimensionname["#{awsnamespace}"]

    $outputmetrics["#{awsnamespace}"].each do |metricname|
    $json_in += <<-EOS
      {
        "OutputAlias": "#{outputalias}",
        "Namespace": "AWS/#{awsnamespace}",
        "MetricName": "#{metricname}",
        "Period": #{period},
        "Statistics": [
          "Average"
        ],
        "Dimensions": [
          {
            "Name": "#{dimensionname}",
            "Value": "#{instance["id"]}",
          }
        ]
      },
EOS

    end
  end
  $json_in += <<-EOS
    ],
    "carbonNameSpacePrefix": "cloudwatch"
  }
}
EOS

  $json_out = Jason.render ( $json_in )
  
  begin 
    $out_file = "output/#{awsnamespace.downcase}-#{awsregion}-#{monitoring}.json"
    file = File.open($out_file, 'w')
    file.write( $json_out )
  rescue IOError => e
    # TODO: do something.
  ensure
    file.close unless file.nil?
  end
end

awsregions.each do |awsregion|
  generateEC2Config(awsregion)
end
