require "functions_framework"
require "kubeclient"
require "googleauth"
require "google/cloud/pubsub"
require "pry-byebug" if ENV["PRY"]

SCOPE = "https://www.googleapis.com/auth/cloud-platform"
TOPIC = "cloudflare-dns-update"
DISCORD_API_URL = "https://discord.com/api/v10"
FOLLOW_UP_PATH_TEMPLATE = "#{DISCORD_API_URL}/webhooks/%{app_id}/%{token}"

FunctionException = Class.new(StandardError)

def mc_scale(apps_client, replicas:)
  apps_client.patch_stateful_set("mc-lutova", { spec: { replicas: replicas } }, "default")
rescue Kubeclient::HttpError => e
  raise FunctionException, <<~ERROR
    Scaling the StatefulSet failed due to Kubernetes Error: "#{e.class}"

    #{e.message}
  ERROR
end

def send_follow_up(message, app_id:, interaction_token:)
  return unless app_id && interaction_token

  Net::HTTP.post(
    URI(FOLLOW_UP_PATH_TEMPLATE % { app_id: app_id, token: interaction_token }),
    { "content" => message }.to_json,
    { "Content-Type" => "application/json" },
  )
end

def kube_client_options
  config = Kubeclient::Config.read(ENV["KUBE_CONFIG"])
  authorizer = Google::Auth::ServiceAccountCredentials.from_env(scope: SCOPE)
  token = authorizer.fetch_access_token!
  context = config.context

  {
    api_endpoint: context.api_endpoint,
    api_version: context.api_version,
    ssl_options: context.ssl_options,
    bearer_token: token["access_token"],
  }
end

def build_apps_client(api_endpoint:, api_version:, ssl_options:, bearer_token:)
  Kubeclient::Client.new("#{api_endpoint}/apis/apps", api_version, ssl_options: ssl_options, auth_options: { bearer_token: bearer_token })
end

def build_kube_client(api_endpoint:, api_version:, ssl_options:, bearer_token:)
  Kubeclient::Client.new(api_endpoint, api_version, ssl_options: ssl_options, auth_options: { bearer_token: bearer_token })
end

def log(msg, logger:, follow_up_options:)
  logger.error(msg)
  return unless follow_up_options
  send_follow_up(msg, **follow_up_options)
end

FunctionsFramework.cloud_event "mc-scale" do |event|
  kube_options = kube_client_options
  apps_client = build_apps_client(**kube_options)
  kube_client = build_kube_client(**kube_options)
  message = JSON.parse(Base64.decode64(event.data.dig("message", "data")))

  follow_up_options = {
    app_id: message["application_id"],
    interaction_token: message["token"],
  }

  event_name = message.dig("data", "name")
  if event_name == "mc-scale"
    subcommand = message.dig("data", "options", 0, "value")

    if subcommand == "on"
      mc_scale(apps_client, replicas: 1)
      client = Google::Cloud::PubSub.new
      topic = client.topic(TOPIC)
      topic.publish("mc-lutova")

      send_follow_up(<<~MSG, **follow_up_options)
        Scaling server up succeeded.
      MSG
    elsif subcommand == "off"
      mc_scale(apps_client, replicas: 0)
      kube_client.delete_service("web-ephemeral", "default")
      send_follow_up(<<~MSG, **follow_up_options)
        Scaling server down succeeded.
      MSG
    elsif subcommand == "status"
      statefulset = apps_client.get_stateful_set("mc-lutova", "default")
      sts_status = statefulset.status

      if sts_status.replicas.zero?
        send_follow_up(<<~MSG, **follow_up_options)
          The server is off.
          #{statefulset.metadata.name} → ready [✗]
        MSG
        return "Handled /#{event_name} #{subcommand}"
      end

      svc = kube_client.get_service("web-ephemeral", "default")
      ip = svc.status&.loadBalancer&.ingress&.first&.ip

      if sts_status.readyReplicas == sts_status.replicas
        send_follow_up(<<~MSG, **follow_up_options)
          The server is on.
          #{statefulset.metadata.name} → ready [✓]
          The ip address is #{ip ? "ready: mc.stride.host (#{ip}:8379)" : "Not Ready"}
        MSG
        return "Handled /#{event_name} #{subcommand}"
      end

      pod = kube_client.get_pod("mc-lutova-0", "default")
      containers = (pod.status.containerStatuses || []).map do |container|
        status = +"#{container.name} → started ["
        status << (container.started ? "✓" : "✗")
        status << "] ready ["
        status << (container.ready ? "✓" : "✗")
        status << "]"
        status
      end.join("\n    ")

      send_follow_up(<<~MSG, **follow_up_options)
        #{statefulset.kind}(#{statefulset.metadata.name}) → ready [✗]
          replicas=#{sts_status.replicas}
          currentReplicas=#{sts_status.currentReplicas}
          readyReplicas=#{sts_status.readyReplicas}

        #{pod.kind}(#{pod.metadata.name}) → #{pod.status.phase.upcase}
          containers=[
            #{containers}
          ]

        #{svc.kind}(#{svc.metadata.name}) → #{ip ? "mc.stride.host (#{ip}:8379)" : "not ready"}
      MSG
    else
      return "Unknown subcommand: #{subcommand}"
    end

    "Handled /#{event_name} #{subcommand}"
  else
    "Unknown Event: /#{event_name}"
  end
rescue FunctionException => e
  log(e.message, logger: logger, follow_up_options: follow_up_options)
rescue Kubeclient::HttpError => e
  log(<<~MSG, logger: logger, follow_up_options: follow_up_options)
    Kubernetes Error: "#{e.class}"

    #{e.message}
    #{e.backtrace}
  MSG
rescue => e
  log(<<~MSG, logger: logger, follow_up_options: follow_up_options)
    Error caught: "#{e.class}"

    #{e.message}
    #{e.backtrace}
  MSG
end
