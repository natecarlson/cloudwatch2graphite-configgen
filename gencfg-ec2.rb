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
$outputmetrics = config['outputmetrics']['EC2']
$skipinstances = config['skipinstances']['RDS']
$matchtags = config['matchtags']['EC2'] unless config['matchtags'].nil?

# Use pretty JSON output format for readability..
Jason.output_format = :pretty

# Output config file for EC2 for a given region
def generateEC2Config(awsregion)

  # Define two lists of nodes to generate config for - basic (standard) monitoring and detailed monitoring..
  ec2instances = Hash.new
  ec2instances["stdmonitor"] = Array.new
  ec2instances["detmonitor"] = Array.new

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
        ec2instance = Hash.new
        ec2instance['id'] = "#@instanceid"
        ec2instance['detailedmonitoring'] = instance.monitoring.state
        ec2instance["tags"] = Hash.new
        instance.tags.each do |tag|
          ec2instance["tags"]["#{tag.key}"]  = "#{tag.value}"
        end
        ec2instance["name"] = "#{ec2instance['tags']['Name']}"

        if ["enabled","pending"].include? ec2instance["detailedmonitoring"]
          ec2instances["detmonitor"].push(ec2instance)
        elsif ["disabled","disabling"].include? ec2instance["detailedmonitoring"]
          ec2instances["stdmonitor"].push(ec2instance)
        else
          abort("Instance #{ec2instance['tags']['Name']} (id #{ec2instance["id"]}) has an invalid field for detailed monitoring: #{ec2instance["detailedmonitoring"]}")
        end
      end
    end
  end

  # Build JSON for 1 minute and 5 minute intervals
  buildjson(awsregion,ec2instances["stdmonitor"],"basic")
  buildjson(awsregion,ec2instances["detmonitor"],"detailed")

end

def buildjson(awsregion,ec2instances,monitoring)
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

  ec2instances.each do |instance|
    # TODO: Support checking against either the name or ID here
    # Check if this instance matches our 'skipinstances' list; if so, move on.
    if $skipinstances.include? "#{instance['name']}"
      puts "Skipping config for: #{instance['name']} (on skipinstances list)"
      next
    end
    
    # If matchtags is defined, validated that this instance matches the tags we've defined - include it if so,
    # otherwise skip it.
    unless $matchtags.nil?
      # Default to excluding the instance; we'll set this to true if the instance matches one or more of the sets of tags.
      includeinstance=false

      $matchtags.each do |matchtag|
        if instance["tags"].contain?( matchtag )
          includeinstance=true
          puts "Including instance #{instance["name"]}, as it matches our match list item #{matchtag}."
        end
      end

      if (includeinstance == false)
        puts "Skipping config for: #{instance['name']} (matchtags doesn't include a tag for it)"
        next
      end
    end
    
    puts "Generating config for: #{instance['name']} (id #{instance['id']})"
    $outputmetrics.each do |metricname|
    $json_in += <<-EOS
      {
        "OutputAlias": "#{instance["name"]}",
        "Namespace": "AWS/EC2",
        "MetricName": "#{metricname}",
        "Period": 60,
        "Statistics": [
          "Average"
        ],
        "Dimensions": [
          {
            "Name": "InstanceId",
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
  
  #$out_file_5m = "output/ec2-#{awsregion}-basic.json"
  begin 
    $out_file = "output/ec2-#{awsregion}-#{monitoring}.json"
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
