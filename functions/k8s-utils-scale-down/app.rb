require "functions_framework"
require "kubeclient"
require "googleauth"
require "google/cloud/pubsub"
require "pry-byebug" if ENV["PRY"]

SCOPE = "https://www.googleapis.com/auth/cloud-platform"
DISCORD_API_URL = "https://discord.com/api/v10"
FOLLOW_UP_PATH_TEMPLATE = "#{DISCORD_API_URL}/webhooks/%{app_id}/%{token}/messages/@original"
HEADERS = { "Content-Type" => "application/json" }

def update_discord_message(message, app_id:, interaction_token:)
  return unless app_id && interaction_token

  uri = URI(FOLLOW_UP_PATH_TEMPLATE % { app_id: app_id, token: interaction_token })
  Net::HTTP.start(uri.host, uri.port, use_ssl: true) do |http|
    request = Net::HTTP::Patch.new(uri, HEADERS)
    request.body = { "content" => message }.to_json

    http.request(request)
  end
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
  update_discord_message(msg, **follow_up_options)
end

FunctionsFramework.cloud_event "k8s-utils-scale-down" do |event|
  kube_options = kube_client_options
  apps_client = build_apps_client(**kube_options)
  kube_client = build_kube_client(**kube_options)
  message = JSON.parse(Base64.decode64(event.data.dig("message", "data")))

  follow_up_options = {
    app_id: message["application_id"],
    interaction_token: message["token"],
  }

  app_name = message.dig("data", "options", 0, "options", 0, "value")

  apps_client.patch_stateful_set("game", { spec: { replicas: 0 } }, app_name)
  kube_client.delete_service("svc", app_name)

  update_discord_message(<<~MSG, **follow_up_options)
    Scaling down server `#{app_name}` succeeded.
  MSG

  "ok"
rescue => e
  log(<<~MSG, logger: logger, follow_up_options: follow_up_options)
    Error caught: "#{e.class}"

    #{e.message}
    #{e.backtrace}
  MSG
end
