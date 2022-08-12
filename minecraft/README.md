# Minecraft

I recommend using [MultiMC](https://multimc.org/) to manage multiple modded instances of Minecraft. See the
[multi-mc.md](docs/multi-mc.md) document for help setting it up.

## Server Information

| | |
|:-|:-|
| Host | mc.stride.host |
| Version | 1.19.1 |

## Changing the Image

```
make release
kubectl delete pod POD_NAME
```

You may need to set `OVERRIDE_SERVER_PROPERTIES=true` for changes that affect `server.properties` and run
`kubectl apply`.
