require "functions_framework"
require "kubeclient"
require "googleauth"
require "ed25519"

PUB_KEY = ENV["VERIFY_KEY"]
PUB_KEY_BYTES = [PUB_KEY].pack("H*").unpack("C*")
VERIFY_KEY = Ed25519::VerifyKey.new(PUB_KEY_BYTES.pack("C*"))

SIG_HEADER = "HTTP_X_SIGNATURE_ED25519"
TS_HEADER = "HTTP_X_SIGNATURE_TIMESTAMP"

SCOPE = "https://www.googleapis.com/auth/cloud-platform"

def mc_scale(body)
  config = Kubeclient::Config.read(".kube/config-v3.yml")
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

  scale_dir = if body.dig("data", "options", 0, "value") == "on"
    { spec: { replicas: 1 } }
  else
    { spec: { replicas: 0 } }
  end

  result = apps_client.patch_stateful_set("mc-lutova", scale_dir, "default")

  {
    "type" => 4,
    "data" => {
      "content" => "Turning the server #{scale_dir[:spec][:replicas].zero? ? "off" : "on"}",
    },
  }
end

FunctionsFramework.http "mc-scale" do |request|
  raw_body = request.body.read
  sig_header = request.get_header(SIG_HEADER)
  sig_bytes = [sig_header].pack("H*").unpack("C*")
  signature = sig_bytes.pack("C*")

  ts_header = request.get_header(TS_HEADER)
  message = ts_header + raw_body

  begin
    VERIFY_KEY.verify(signature, message)
  rescue Ed25519::VerifyError
    return [401, {}, ["invalid request signature"]]
  end
  body = JSON.parse(raw_body)

  return { "type" => 1 } if body["type"] == 1
  return mc_scale(body) if body.dig("data", "name") == "mc-scale"

  {
    "type" => 4,
    "data" => {
      "content" => "Unknown command.",
    },
  }
end
