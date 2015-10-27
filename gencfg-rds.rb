#!/usr/bin/ruby

require 'aws-sdk-core'
require 'aws-sdk-resources'
require 'json'
require 'jason'

# Temp hack - load credentials from JSON file; this should change to a real config file.
creds = JSON.load(File.read('creds.json'))
Aws.config[:credentials] = Aws::Credentials.new(creds['awsCredentials']['accessKeyId'], creds['awsCredentials']['secretAccessKey'])

# Use pretty JSON output format for readability..
Jason.output_format = :pretty

# AWS Configuration
@awsregion = "us-east-1"
@awsaccountnumber = creds['awsCredentials']['accountNumber']

# Items to output for each host in the JSON config; check the AWS CloudWatch page to get a list,
# IE, for RDS, http://docs.aws.amazon.com/AmazonCloudWatch/latest/DeveloperGuide/rds-metricscollected.html
outputmetricnames = ["CPUUtilization", "DatabaseConnections", "DiskQueueDepth", "FreeableMemory", "FreeStorageSpace", "SwapUsage", "ReadIOPS", "WriteIOPS", "ReadLatency", "WriteLatency", "ReadThroughput", "WriteThroughput", "NetworkReceiveThroughput", "NetworkTransmitThroughput"]

Aws.config.update({
	region: "#@awsregion",
})

rdsinstances = Array.new

rds = Aws::RDS::Client.new(region: @awsregion)
rds.describe_db_instances.each do |instances|
	instances.db_instances.each do |instance|
		@instancename = instance.db_instance_identifier
		# AWS's SDK is silly, and doesn't let you look up tags based on a RDS DB name. Have to
		# pass in an 'ARN' instead - and the SDK doesn't provide the ARN to us. Have to generate it.
		# Really, really lame.
		@instancearn = "arn:aws:rds:#@awsregion:#@awsaccountnumber:db:#@instancename"
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
			rdsinstances.push(rdsinstance)
		end
	end
end

puts Jason.render(<<-EOS
{
  "awsCredentials": {
    "accessKeyId": <%= creds['awsCredentials']['accessKeyId'] %>,
    "secretAccessKey": <%= creds['awsCredentials']['secretAccessKey'] %>,
    "region": <%= @awsregion %>,
  },  
  "metricsConfig": {
    "metrics": [
<% rdsinstances.each do |instance| -%>
  <% outputmetricnames.each do |metricname| -%>
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
