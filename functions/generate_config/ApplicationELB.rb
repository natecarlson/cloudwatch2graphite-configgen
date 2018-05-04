# Output config file for ApplicationELB (ALB/ELBv2) for a given region
# TODO: Add additional logic to support parsing stats for each target under an ALB
def generate_config_ApplicationELB(awsregion,awsservice)
  applicationelbinstances = Array.new
  applicationelbtargetgroupinstances = Array.new

  Aws.config.update({
    region: "#{awsregion}",
  })

  applicationelb = Aws::ElasticLoadBalancingV2::Client.new(region: awsregion)
  applicationelb.describe_load_balancers.each do |instances|
    instances.load_balancers.each do |instance|
      instancename = instance.load_balancer_name
      instancearn = instance.load_balancer_arn

      unless $skipinstances.nil?
        unless $skipinstances['ApplicationELB'].nil?
          if $skipinstances['ApplicationELB'].include? "#{instancename}"
            $log.debug("Skipping config for: #{instancename} (on skipinstances list)")
            next
          end
        end
      end

      applicationelbinstance = Hash.new
      applicationelbinstance['name'] = instancename
      # The ID is the last section of the ARN, with sections separated by colons.
      # ..but there is also a stray 'loadbalancer/' in front of it. Sigh.
      applicationelbinstance['id'] = instancearn.rpartition('loadbalancer/').last
      applicationelbinstance["tags"] = Hash.new
      applicationelb.describe_tags({ resource_arns: [ "#{instancearn}" ] }).tag_descriptions.each do |tags|
        tags.tags.each do |tag|
          applicationelbinstance["tags"]["#{tag.key}"]  = "#{tag.value}"
        end
      end

      # TODO: What's the right way to figure out if both a parent and child are null?
      unless $matchtags.nil?
        unless $matchtags['ApplicationELB'].nil?
          # Default to excluding the instance; we'll set this to true if the instance matches one or more of the sets of tags.
          includeinstance=false

          $matchtags['ApplicationELB'].each do |matchtag|
            includeinstance=true if applicationelbinstance["tags"].contain?( matchtag )
          end

          if (includeinstance == false)
            $log.debug("Skipping config for: #{applicationelbinstance['name']} (matchtags doesn't include a tag for it)")
            next
          end
        end
      end

      # Iterate over the target groups..
      applicationelb.describe_target_groups( { load_balancer_arn: "#{instancearn}" }).target_groups.each do |targetgroup|
        applicationelbtargetgroupinstance = Hash.new
        # Specify parent ELB, for use in the json building exercise
        applicationelbtargetgroupinstance['parent'] = instancename
        # Ugh. Also need to include parent id, as have to do two dimensions..
        applicationelbtargetgroupinstance['parentid'] = applicationelbinstance['id']
        # Gonna specify our own name, not use the AWS name..
        #applicationelbtargetgroupinstance['name'] = targetgroup.target_group_name
        applicationelbtargetgroupinstance['arn'] = targetgroup.target_group_arn
        # The Target group ID is the last section of the ARN, with sections separate by colons.
        applicationelbtargetgroupinstance['id'] = applicationelbtargetgroupinstance['arn'].rpartition(':').last
        applicationelbtargetgroupinstance["tags"] = Hash.new
        tags = applicationelb.describe_tags({ resource_arns: [ "#{applicationelbtargetgroupinstance['arn']}" ] }).tag_descriptions.each do |tags|
          tags.tags.each do |tag|
            applicationelbtargetgroupinstance["tags"]["#{tag.key}"]  = "#{tag.value}"
          end
        end

        # Take the name tag, strip off the application elb name from the front, and use it as our name..
        # TODO: Fallback to the actual 'name' parameter if this doesn't give us anything useful.
        instancenamestrippedalb = instancename.sub('alb','')
        applicationelbtargetgroupinstance['name'] = applicationelbtargetgroupinstance["tags"]["Name"].sub(instancenamestrippedalb,'')

        applicationelbtargetgroupinstances.push(applicationelbtargetgroupinstance)
      end

      applicationelbinstances.push(applicationelbinstance)
    end
  end
  dimensionname = $dimensionname["#{awsservice}"]
  buildjson(awsregion,applicationelbinstances,"#{awsservice}","detailed",60,"#{dimensionname}")

  # Build JSON for target groups
  buildjson(awsregion,applicationelbtargetgroupinstances,"ApplicationELB-Target","detailed",60,"TargetGroup")
end
