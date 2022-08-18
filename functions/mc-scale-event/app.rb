require "functions_framework"
require "kubeclient"
require "googleauth"
require "pry-byebug" if ENV["PRY"]

SCOPE = "https://www.googleapis.com/auth/cloud-platform"
DISCORD_API_URL = "https://discord.com/api/v10"
FOLLOW_UP_PATH_TEMPLATE = "#{DISCORD_API_URL}/webhooks/%{app_id}/%{token}"

def mc_scale(apps_client, replicas:)
  apps_client.patch_stateful_set("mc-lutova", { spec: { replicas: replicas } }, "default")
end

def send_follow_up(message, app_id:, interaction_token:)
  Net::HTTP.post(
    URI(FOLLOW_UP_PATH_TEMPLATE % { app_id: app_id, token: interaction_token }),
    { "content" => message }.to_json,
    { "Content-Type" => "application/json" },
  )
end

FunctionsFramework.cloud_event "mc-scale" do |event|
  message = begin
    JSON.parse(Base64.decode64(event.data["message"]["data"]))
  rescue => e
    return "Error: #{e.message}"
  end

  config = Kubeclient::Config.read(ENV["KUBE_CONFIG"])
  authorizer = Google::Auth::ServiceAccountCredentials.from_env(scope: SCOPE)
  token = authorizer.fetch_access_token!
  context = config.context
  apps_endpoint = [context.api_endpoint, 'apis/apps'].join('/')

  apps_client = Kubeclient::Client.new(
    apps_endpoint,
    context.api_version,
    ssl_options: context.ssl_options,
    auth_options: {
      bearer_token: token["access_token"],
    },
  )

  event_name = message.dig("data", "name")
  if event_name == "mc-scale"
    subcommand = message.dig("data", "options", 0, "value")

    if subcommand == "on"
      mc_scale(apps_client, replicas: 1)
    elsif subcommand == "off"
      mc_scale(apps_client, replicas: 0)
    elsif subcommand == "status"
      send_follow_up(
        "The server is off?",
        app_id: message["application_id"],
        interaction_token: message["token"],
      )
    else
      return "Unknown subcommand: #{subcommand}"
    end

    "Handling /#{event_name} #{subcommand}"
  else
    "Unknown Event: /#{event_name}"
  end
end
