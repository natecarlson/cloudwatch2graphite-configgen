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
$outputmetrics = config['outputmetrics']['EC2']

# Use pretty JSON output format for readability..
Jason.output_format = :pretty

# Output config file for EC2 for a given region
def generateEC2Config(awsregion)
  @awsregion = awsregion
  @ec2instances = Array.new

  Aws.config.update({
	  region: "#{awsregion}",
  })

  ec2 = Aws::EC2::Client.new(region: awsregion)

  ec2.describe_instances({ filters: [ { name: "tag:env", values: ["prod"] }, { name: "instance-state-name", values: ["running"] } ] } ).each do |reservations|
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
        @ec2instances.push(ec2instance)
      end
    end
  end

  # TODO - clean this crap up, I don't like how I'm doing this at all. Should only have one routine to build the JSON and have sparate calls for basic vs detailed monitoring..
  # TODO - figure out how to better namespace output to Carbon, so that we can have separate storage aggregations for 1m vs 5m
  $json_1m = Jason.render(<<-EOS
{
  "awsCredentials": {
    "accessKeyId": <%= $creds['awsCredentials']['accessKeyId'] %>,
    "secretAccessKey": <%= $creds['awsCredentials']['secretAccessKey'] %>,
    "region": <%= @awsregion %>,
  },  
  "metricsConfig": {
    "metrics": [
<% @ec2instances.each do |instance| -%>
<% next if ["disabled","disabling"].include? instance["detailedmonitoring"] -%>
  <% $outputmetrics.each do |metricname| -%>
      {
        "OutputAlias": <%= instance["name"] %>,
        "Namespace": "AWS/EC2",
        "MetricName": <%= metricname %>,
        "Period": 60,
        "Statistics": [
          "Average"
        ],
        "Dimensions": [
          {
            "Name": "InstanceId",
            "Value": <%= instance["id"] %>,
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
  $json_5m = Jason.render(<<-EOS
{
  "awsCredentials": {
    "accessKeyId": <%= $creds['awsCredentials']['accessKeyId'] %>,
    "secretAccessKey": <%= $creds['awsCredentials']['secretAccessKey'] %>,
    "region": <%= @awsregion %>,
  },  
  "metricsConfig": {
    "metrics": [
<% @ec2instances.each do |instance| -%>
<% next if ["enabled","pending"].include? instance["detailedmonitoring"] -%>
  <% $outputmetrics.each do |metricname| -%>
      {
        "OutputAlias": <%= instance["name"] %>,
        "Namespace": "AWS/EC2",
        "MetricName": <%= metricname %>,
        "Period": 300,
        "Statistics": [
          "Average"
        ],
        "Dimensions": [
          {
            "Name": "InstanceId",
            "Value": <%= instance["id"] %>,
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

  # Write 1m file 
  begin 
    $out_file_1m = "output/ec2-#{awsregion}-detailed.json"
    file = File.open($out_file_1m, 'w')
    file.write( $json_1m )
  rescue IOError => e
    # TODO: do something.
  ensure
    file.close unless file.nil?
  end
  
  # Write 5m file 
  begin 
    $out_file_5m = "output/ec2-#{awsregion}-basic.json"
    file = File.open($out_file_5m, 'w')
    file.write( $json_5m )
  rescue IOError => e
    # TODO: do something.
  ensure
    file.close unless file.nil?
  end
end

awsregions.each do |awsregion|
  generateEC2Config(awsregion)
end

