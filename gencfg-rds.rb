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
$outputmetrics = config['outputmetrics']['RDS']
$skipinstances = config['skipinstances']['RDS']
$matchtags = config['matchtags']['RDS'] unless config['matchtags'].nil?

# Use pretty JSON output format for readability..
Jason.output_format = :pretty

# Output config file for RDS for a given region
def generateRDSConfig(awsregion)
  @awsregion = awsregion
  @rdsinstances = Array.new

  Aws.config.update({
	  region: "#{awsregion}",
  })

  puts "Starting configs for service RDS, region #{awsregion}"
  rds = Aws::RDS::Client.new(region: awsregion)
  rds.describe_db_instances.each do |instances|
	  instances.db_instances.each do |instance|
		  @instancename = instance.db_instance_identifier
  		# AWS's SDK is silly, and doesn't let you look up tags based on a RDS DB name. Have to
	  	# pass in an 'ARN' instead - and the SDK doesn't provide the ARN to us. Have to generate it.
		  # Really, really lame.
  		@instancearn = "arn:aws:rds:#{awsregion}:#$awsaccountnumber:db:#@instancename"
	  	rdsinstance = Hash.new
		  rdsinstance['name'] = "#@instancename"
  		rdsinstance['arn']  = "#@instancearn"
	  	rdsinstance["tags"] = Hash.new
		  rds.list_tags_for_resource({ resource_name: @instancearn }).each do |tags|
  			tags.tag_list.each do |tag|
	  			rdsinstance["tags"]["#{tag.key}"]  = "#{tag.value}"
		  	end
  		end

      @rdsinstances.push(rdsinstance)
	  end
  end

  # Prep our JSON output.. this will get passed through Jason later to properly comma-ize/etc.
  $json_in = <<-EOS
{
  "awsCredentials": {
    "accessKeyId": "#{$creds['awsCredentials']['accessKeyId']}",
    "secretAccessKey": "#{$creds['awsCredentials']['secretAccessKey']}",
    "region": "#@awsregion",
  },  
  "metricsConfig": {
    "metrics": [
EOS

  @rdsinstances.each do |instance|
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
        includeinstance=true if instance["tags"].contain?( matchtag )
      end

      if (includeinstance == false)
        puts "Skipping config for: #{instance['name']} (matchtags doesn't include a tag for it)"
        next
      end
    end


    puts "Generating config for: #{instance['name']}"

    $outputmetrics.each do |metricname|
      $json_in += <<-EOS
      {
        "Namespace": "AWS/RDS",
        "MetricName": "#{metricname}",
        "Period": 60,
        "Statistics": [
          "Average"
        ],
        "Dimensions": [
          {
            "Name": "DBInstanceIdentifier",
            "Value": "#{instance['name']}",
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
  $json_out = Jason.render( $json_in )

  begin 
    $out_file = "output/rds-#{awsregion}.json"
    file = File.open($out_file, 'w')
    file.write( $json_out )
  rescue IOError => e
    # TODO: do something.
  ensure
    file.close unless file.nil?
  end

end

awsregions.each do |awsregion|
  generateRDSConfig(awsregion)
end

