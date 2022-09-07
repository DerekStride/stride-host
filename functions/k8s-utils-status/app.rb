require "functions_framework"
require "kubeclient"
require "googleauth"
require "google/cloud/pubsub"
require "pry-byebug" if ENV["PRY"]

SCOPE = "https://www.googleapis.com/auth/cloud-platform"
DISCORD_API_URL = "https://discord.com/api/v10"
FOLLOW_UP_PATH_TEMPLATE = "#{DISCORD_API_URL}/webhooks/%{app_id}/%{token}"

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

APPLICATIONS = [
  "mc-lutova",
  "mc-create",
  "mc-survival",
  "terraria-0",
]

FunctionsFramework.cloud_event "k8s-utils-status" do |event|
  kube_options = kube_client_options
  apps_client = build_apps_client(**kube_options)
  kube_client = build_kube_client(**kube_options)
  message = JSON.parse(Base64.decode64(event.data.dig("message", "data")))

  follow_up_options = {
    app_id: message["application_id"],
    interaction_token: message["token"],
  }

  buffer = +''

  APPLICATIONS.each do |app_name|
    statefulset = apps_client.get_stateful_set("game", app_name)
    sts_status = statefulset.status

    if sts_status.replicas.zero?
      buffer << <<~MSG
        `#{app_name}` is off.
          #{statefulset.metadata.name} → ready [✗]

      MSG
      next
    end

    svc = kube_client.get_service("svc", app_name)
    ip = svc.status&.loadBalancer&.ingress&.first&.ip

    if sts_status.readyReplicas == sts_status.replicas
      buffer << <<~MSG
        `#{app_name}` is on.
          #{statefulset.metadata.name} → ready [✓]
          The ip address is #{ip ? "ready: #{app_name}.stride.host (#{ip}:8379)" : "not ready"}

      MSG
      next
    end

    pod = kube_client.get_pod("game-0", app_name)
    containers = (pod.status.containerStatuses || []).map do |container|
      status = +"#{container.name} → started ["
      status << (container.started ? "✓" : "✗")
      status << "] ready ["
      status << (container.ready ? "✓" : "✗")
      status << "]"
      status
    end.join("\n    ")

    buffer << <<~MSG
      #{statefulset.kind}(#{statefulset.metadata.name}) → ready [✗]
        replicas=#{sts_status.replicas}
        currentReplicas=#{sts_status.currentReplicas}
        readyReplicas=#{sts_status.readyReplicas}

      #{pod.kind}(#{pod.metadata.name}) → #{pod.status.phase.upcase}
        containers=[
          #{containers}
        ]

      #{svc.kind}(#{svc.metadata.name}) → #{ip ? "#{app_name}.stride.host (#{ip}:8379)" : "not ready"}

    MSG
  end

  send_follow_up(buffer.chomp, **follow_up_options)

  "ok"
rescue => e
  log(<<~MSG, logger: logger, follow_up_options: follow_up_options)
    Error caught: "#{e.class}"

    #{e.message}
    #{e.backtrace}
  MSG
end
