require "functions_framework"
require "net/http"
require "kubeclient"
require "googleauth"
require "pry-byebug" if ENV["PRY"]

SCOPE = "https://www.googleapis.com/auth/cloud-platform"
CLOUDFLARE_MC_RECORD = URI("https://api.cloudflare.com/client/v4/zones/a6aea1807747acd56c916c3dd5b8ba05/dns_records/86adf4312d129c973357da33a910a70e")
PAYLOAD = {
  type: "A",
  name: "mc",
  ttl: 1,
  proxied: false,
}

HEADERS = {
  "Content-Type" => "application/json",
  "Authorization" => "Bearer #{ENV["CLOUDFLARE_TOKEN"]}",
}

RETRIES = 10

SERVICE_META = {
  name: "web-ephemeral",
  namespace: "default",
  annotations: {
    :"cloud.google.com/network-tier" => "Standard",
    :"networking.gke.io/load-balancer-type" => "External",
  },
}

SERVICE_SPEC = {
  type: "LoadBalancer",
  selector: {
    app: "mc-lutova",
  },
  ports: [
    {
      name: "tcp",
      port: 8379,
      targetPort: 25565,
      protocol: "TCP",
    },
  ],
}

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

def build_kube_client(api_endpoint:, api_version:, ssl_options:, bearer_token:)
  Kubeclient::Client.new(api_endpoint, api_version, ssl_options: ssl_options, auth_options: { bearer_token: bearer_token })
end

FunctionsFramework.cloud_event "cloudflare-dns-update" do |event|
  kube_options = kube_client_options
  kube_client = build_kube_client(**kube_options)

  begin
    kube_client.get_service("web-ephemeral", "default")
  rescue Kubeclient::ResourceNotFoundError
    logger.info("service does not exist, creating...")
    svc = Kubeclient::Resource.new(metadata: SERVICE_META, spec: SERVICE_SPEC)
    kube_client.create_service(svc)
    sleep(40)
  end

  pod = kube_client.get_pod("mc-lutova-0", "default")
  unless pod.status.phase == "Running"
    logger.info("pod status is #{pod.status.phase}, likely creating a new node, sleeping some more...")
    sleep(240)
  end

  ip = nil
  count = 0

  logger.info("fetching ip address...")
  loop do
    service = kube_client.get_service("web-ephemeral", "default")
    ip = service&.status&.loadBalancer&.ingress&.first&.ip
    break if ip

    count += 1
    break if count >= RETRIES

    logger.info("fetching ip address... retrying again later: #{count} attempt(s).")
    sleep(20)
  end

  unless ip
    logger.error("No external IP address for service: web-ephemeral")
    logger.error(service.status.inspect)
    return "error"
  end

  response = Net::HTTP.get(CLOUDFLARE_MC_RECORD, HEADERS)
  data = JSON.parse(response)

  if ip == data.dig("result", "content")
    logger.info("Ip hasn't changed, current value: #{ip}")
    return "ok"
  end

  logger.info("updating cloudflare...")
  response = Net::HTTP.start(CLOUDFLARE_MC_RECORD.host, CLOUDFLARE_MC_RECORD.port, use_ssl: true) do |http|
    request = Net::HTTP::Put.new(CLOUDFLARE_MC_RECORD, HEADERS)
    request.body = PAYLOAD.merge(content: ip).to_json

    http.request(request)
  end

  logger.info(response.class.name)
  logger.info(response.body)

  "ok"
end
