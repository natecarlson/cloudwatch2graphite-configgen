# Output config file for SNS for a given region
def generate_config_SNS(awsregion,awsservice)
  snsinstances = Array.new

  Aws.config.update({
    region: awsregion
  })

  sns = Aws::SNS::Client.new(region: awsregion)

  sns.list_topics

  sns.list_platform_applications.each do |endpoint|
    puts endpoint[0]
  end
end
