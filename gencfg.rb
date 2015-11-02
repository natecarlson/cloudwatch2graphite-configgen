#!/usr/bin/ruby

require 'aws-sdk-core'
require 'aws-sdk-resources'
require 'json'
require 'jason'
require 'fileutils'
require 'logger'

# Use Logger to let us set a debug level and filter out stuff we don't want..
$log = Logger.new(STDOUT)
class CustomFormatter < Logger::Formatter
  def call(severity, time, progname, msg)
   # msg2str is the internal helper that handles different msgs correctly
    "#{time} - #{msg2str(msg)}" + "\n"
  end
end
$customformatter = CustomFormatter.new
$log.progname = "cw2graphite-cfggen"
$log.formatter = proc { |severity, datetime, progname, msg|
  $customformatter.call(severity, datetime, progname, msg.dump)
}
# Use DEBUG to see messages about hosts that we've skipped
$log.level = Logger::INFO

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

# Pull in config, and go ahead and throw errors now if the config is invalid..
if config['awsservices'].nil?
  abort("No 'awsservices' in the config file - we can't do that..")
else
  # Even though we hit these one at a time, make it global, so we can enable/disable sub-services like EC2->EBS
  $awsservices = config['awsservices']
end
if config['regions'].nil?
  abort("No 'regions' in the config file - we can't do that..")
else
  # Not a global - we'll cycle through these one at a time.
  awsregions = config['regions']
end
if config['outputmetrics'].nil?
  abort("No 'outputmetrics' in the config file - we can't do that..")
else
  $outputmetrics = config['outputmetrics']
end
if config['dimensionname'].nil?
  abort("No 'dimensionname' in the config file - we can't do that..")
else
  $dimensionname = config['dimensionname']
end
$skipinstances = config['skipinstances'] unless config['skipinstances'].nil?
$matchtags = config['matchtags'] unless config['matchtags'].nil?

# Use pretty JSON output format for readability..
Jason.output_format = :pretty

# Output config file for EC2 for a given region
def generate_config_EC2(awsregion)

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
        unless $skipinstances.nil?
          unless $skipinstances['EC2'].nil?
            if $skipinstances["EC2"].include? "#{ec2instance['name']}"
              $log.debug("Skipping config for: #{ec2instance['name']} (on skipinstances list)")
              next
            end
          end
        end
    
        # If matchtags is defined, validated that this instance matches the tags we've defined - include it if so,
        # otherwise skip it.
        # TODO: What's the right way to figure out if both a parent and child are null?
        unless $matchtags.nil?
          unless $matchtags['EC2'].nil?
            # Default to excluding the instance; we'll set this to true if the instance matches one or more of the sets of tags.
            includeinstance=false
  
            $matchtags['EC2'].each do |matchtag|
              includeinstance=true if ec2instance["tags"].contain?( matchtag )
            end

            if (includeinstance == false)
              $log.debug("Skipping config for: #{ec2instance['name']} (matchtags doesn't include a tag for it)")
              next
            end
          end
        end

        if ["enabled","pending"].include? ec2instance["detailedmonitoring"]
          ec2instances["detailed"].push(ec2instance)
        elsif ["disabled","disabling"].include? ec2instance["detailedmonitoring"]
          ec2instances["basic"].push(ec2instance)
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
  buildjson(awsregion,ec2instances["basic"],"EC2","basic",300)
  buildjson(awsregion,ec2instances["detailed"],"EC2","detailed",60)

  if $awsservices.include? "EBS"
    # Build JSON for Standard and PIOPS EBS disk (5m and 1m intervals)
    buildjson(awsregion,ebsvolumes["basic"],"EBS","basic",300)
    buildjson(awsregion,ebsvolumes["detailed"],"EBS","detailed",60)
  end
end

# Output config file for RDS for a given region
def generate_config_RDS(awsregion)
  rdsinstances = Array.new

  Aws.config.update({
	  region: "#{awsregion}",
  })

  $log.info("Starting configs for service RDS, region #{awsregion}")
  rds = Aws::RDS::Client.new(region: awsregion)
  rds.describe_db_instances.each do |instances|
	  instances.db_instances.each do |instance|
      unless $skipinstances.nil?
        unless $skipinstances['RDS'].nil?
          if $skipinstances['RDS'].include? "#{instance.db_instance_identifier}"
            $log.debug("Skipping config for: #{instance.db_instance_identifier} (on skipinstances list)")
            next
          end
        end
      end

		  instancename = instance.db_instance_identifier

  		# AWS's SDK is silly, and doesn't let you look up tags based on a RDS DB name. Have to
	  	# pass in an 'ARN' instead - and the SDK doesn't provide the ARN to us. Have to generate it.
		  # Really, really lame.
  		instancearn = "arn:aws:rds:#{awsregion}:#$awsaccountnumber:db:#{instancename}"
	  	
      rdsinstance = Hash.new
      # RDS doesn't have a distinct ID separate from the name - so set both the same
		  rdsinstance['name'] = instancename
		  rdsinstance['id'] = instancename
  		rdsinstance['arn']  = instancearn
	  	rdsinstance["tags"] = Hash.new
		  rds.list_tags_for_resource({ resource_name: instancearn }).each do |tags|
  			tags.tag_list.each do |tag|
	  			rdsinstance["tags"]["#{tag.key}"]  = "#{tag.value}"
		  	end
  		end

      # TODO: What's the right way to figure out if both a parent and child are null?
      unless $matchtags.nil?
        unless $matchtags['RDS'].nil?
          # Default to excluding the instance; we'll set this to true if the instance matches one or more of the sets of tags.
          includeinstance=false

          $matchtags['RDS'].each do |matchtag|
            includeinstance=true if rdsinstance["tags"].contain?( matchtag )
          end

          if (includeinstance == false)
            $log.debug("Skipping config for: #{rdsinstance['name']} (matchtags doesn't include a tag for it)")
            next
          end
        end
      end

      rdsinstances.push(rdsinstance)
	  end
  end
  
  buildjson(awsregion,rdsinstances,"RDS","detailed",60)
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
    $log.info("Generating config for: #{instance['name']} (id #{instance['id']})")

    if awsnamespace == "EBS"
      outputalias = "#{monitoring}.#{instance["name"]}.#{instance["blockdev"].gsub('/dev/','')}"
    else
      outputalias = "#{monitoring}.#{instance["name"]}"
    end

    dimensionname = $dimensionname["#{awsnamespace}"]

    $outputmetrics["#{awsnamespace}"].each do |metricname, stattype|
    $json_in += <<-EOS
      {
        "OutputAlias": "#{outputalias}",
        "Namespace": "AWS/#{awsnamespace}",
        "MetricName": "#{metricname}",
        "Period": #{period},
        "Statistics": [
          "#{stattype}"
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
  # Others..
  $log.info("--- Generating config for AWS Region: #{awsregion} ---")
    $awsservices.each do |awsservice|
    # EBS is a special case; we do it as part of the EC2 generation.
    next if awsservice.downcase == "ebs"

    $log.info("--- Generating config for AWS Region: #{awsregion}; service #{awsservice} ---")
    if (awsservice.downcase == "ec2")
      generate_config_EC2(awsregion)
    elsif (awsservice.downcase == "rds")
      generate_config_RDS(awsregion)
    else
      abort("Uh, crap, we don't know how to generate the config for #{awsservice}...")
    end
  end
end
