require "functions_framework"
require "kubeclient"
require "googleauth"
require "pry-byebug" if ENV["PRY"]

SCOPE = "https://www.googleapis.com/auth/cloud-platform"

def mc_scale(apps_client, replicas:)
  apps_client.patch_stateful_set("mc-lutova", { spec: { replicas: replicas } }, "default")
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
    if message.dig("data", "options", 0, "value") == "on"
      mc_scale(apps_client, replicas: 1)
    else
      mc_scale(apps_client, replicas: 0)
    end

    "Scaling mc-lutova"
  else
    "Unknown Event: #{event_name}"
  end
end
