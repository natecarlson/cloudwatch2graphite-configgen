#!/usr/bin/ruby

require 'aws-sdk-core'
require 'aws-sdk-resources'
require 'json'
require 'jason'
require 'fileutils'

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

# Use pretty JSON output format for readability..
Jason.output_format = :pretty

# Output config file for RDS for a given region
def generateRDSConfig(awsregion)
  @awsregion = awsregion
  @rdsinstances = Array.new

  Aws.config.update({
	  region: "#{awsregion}",
  })

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

	  	if rdsinstance["tags"]["env"] == "prod" then
		  	@rdsinstances.push(rdsinstance)
  		end
	  end
  end

  $json_out = Jason.render(<<-EOS
{
  "awsCredentials": {
    "accessKeyId": <%= $creds['awsCredentials']['accessKeyId'] %>,
    "secretAccessKey": <%= $creds['awsCredentials']['secretAccessKey'] %>,
    "region": <%= @awsregion %>,
  },  
  "metricsConfig": {
    "metrics": [
<% @rdsinstances.each do |instance| -%>
  <% $outputmetrics.each do |metricname| -%>
      {
        "Namespace": "AWS/RDS",
        "MetricName": <%= metricname %>,
        "Period": 60,
        "Statistics": [
          "Average"
        ],
        "Dimensions": [
          {
            "Name": "DBInstanceIdentifier",
            "Value": <%= instance["name"] %>,
          }
        ]
      },
  <% end -%>
<% end -%>
    ],
    "carbonNameSpacePrefix": "cloudwatch"
  }
}
EOS
  )

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

