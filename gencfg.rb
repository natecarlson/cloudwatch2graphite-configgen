#!/usr/bin/env ruby

require 'aws-sdk'
require 'json'
require 'jason'
require 'fileutils'
require 'logger'

require_relative 'functions/generate_config/EC2'
require_relative 'functions/generate_config/RDS'
require_relative 'functions/generate_config/ELB'
require_relative 'functions/generate_config/ApplicationELB'
require_relative 'functions/generate_config/ElastiCache'
require_relative 'functions/generate_config/DMS'
require_relative 'functions/generate_config/SNS'

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
#$log.level = Logger::DEBUG

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
  $log.error("No 'awsservices' in the config file - we can't do that..")
  abort
else
  # Even though we hit these one at a time, make it global, so we can enable/disable sub-services like EC2->EBS
  $awsservices = config['awsservices']
end
if config['regions'].nil?
  $log.error("No 'regions' in the config file - we can't do that..")
  abort
else
  # Not a global - we'll cycle through these one at a time.
  awsregions = config['regions']
end
if config['outputmetrics'].nil?
  $log.error("No 'outputmetrics' in the config file - we can't do that..")
  abort
else
  $outputmetrics = config['outputmetrics']
end
if config['dimensionname'].nil?
  $log.error("No 'dimensionname' in the config file - we can't do that..")
  abort
else
  $dimensionname = config['dimensionname']
end
$skipinstances = config['skipinstances'] unless config['skipinstances'].nil?
$matchtags = config['matchtags'] unless config['matchtags'].nil?

# Use pretty JSON output format for readability..
Jason.output_format = :pretty

def buildjson(awsregion,instances,awsservice,monitoring,period,dimensionname)
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
    $log.info("Building JSON for: #{awsservice} - #{instance['name']} (id #{instance['id']})")

    if awsservice.downcase == "ebs"
      outputalias = "#{monitoring}.#{instance["name"].downcase}.#{instance["blockdev"].gsub('/dev/','')}"
    elsif awsservice.downcase == "applicationelb-target"
      outputalias="#{monitoring}.#{instance["parent"].downcase}.targets.#{instance["name"].downcase}"
    elsif awsservice.downcase == "elasticache-node-memcache"
      outputalias="#{monitoring}.memcache.#{instance["parent"].downcase}.nodes.#{instance["name"].downcase}"
    elsif awsservice.downcase == "elasticache-node-redis"
      outputalias="#{monitoring}.redis.#{instance["parent"].downcase}.nodes.#{instance["name"].downcase}"
    else
      outputalias = "#{monitoring}.#{instance["name"].downcase}"
    end

    # With ALB/ELBv2/ApplicationELB, AWS started breaking the rule of namespace being in all caps..
    # So, do hacks to support that.
    # Ditto for Elasticache..
    if awsservice.downcase == "applicationelb"
      outputawsservice = "ApplicationELB"
    elsif awsservice.downcase == "applicationelb-target"
      outputawsservice = "ApplicationELB"
    elsif awsservice.downcase == "elasticache-node-memcache"
      outputawsservice = "ElastiCache"
    elsif awsservice.downcase == "elasticache-node-redis"
      outputawsservice = "ElastiCache"
    else
      outputawsservice = awsservice.upcase
    end

    $outputmetrics["#{awsservice}"].each do |metricname, stattype|
      # HACK HACK HACK! Have to specify two dimensions for ApplicationELB Targets.. so do an if statement here.
      # TODO: FIX THIS. Duplication == BAD.
      if awsservice.downcase == "applicationelb-target"
        $json_in += <<-EOS
      {
        "OutputAlias": "#{outputalias}",
        "Namespace": "AWS/#{outputawsservice}",
        "MetricName": "#{metricname}",
        "Period": #{period},
        "Statistics": [
          "#{stattype}"
        ],
        "Dimensions": [
          {
            "Name": "LoadBalancer",
            "Value": "#{instance["parentid"]}",
          },
          {
            "Name": "#{dimensionname}",
            "Value": "#{instance["id"]}",
          }
        ]
      },
EOS
      elsif ( awsservice.downcase =~ /^elasticache-node(.*)/ )
        $json_in += <<-EOS
      {
        "OutputAlias": "#{outputalias}",
        "Namespace": "AWS/#{outputawsservice}",
        "MetricName": "#{metricname}",
        "Period": #{period},
        "Statistics": [
          "#{stattype}"
        ],
        "Dimensions": [
          {
            "Name": "CacheClusterId",
            "Value": "#{instance["parentid"]}",
          },
          {
            "Name": "#{dimensionname}",
            "Value": "#{instance["id"]}",
          }
        ]
      },
EOS
      else
        $json_in += <<-EOS
      {
        "OutputAlias": "#{outputalias}",
        "Namespace": "AWS/#{outputawsservice}",
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
  end
  $json_in += <<-EOS
    ],
    "carbonNameSpacePrefix": "cloudwatch"
  }
}
EOS

  $json_out = Jason.render ( $json_in )

  begin
    $out_file = "output/#{awsservice.downcase}-#{awsregion}-#{monitoring}.json"
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
      generate_config_EC2(awsregion,awsservice)
    elsif (awsservice.downcase == "rds")
      generate_config_RDS(awsregion,awsservice)
    elsif (awsservice.downcase == "elb")
      generate_config_ELB(awsregion,awsservice)
    elsif (awsservice.downcase == "applicationelb")
      generate_config_ApplicationELB(awsregion,awsservice)
    elsif (awsservice.downcase == "elasticache")
      generate_config_ElastiCache(awsregion,awsservice)
    elsif (awsservice.downcase == "dms")
      generate_config_DMS(awsregion,awsservice)
    elsif (awsservice.downcase == 'sns')
      generate_config_SNS(awsregion,awsservice)
    else
      $log.error("This script cannot generate configuration for #{awsservice}; sorry!")
      abort
    end
  end
end
