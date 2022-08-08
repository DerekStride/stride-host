prune:
	docker container prune -f

serve: prune
	docker run \
		-e EULA=true \
		-e VERSION=1.19.1 \
		-e SERVER_NAME=Lutova \
		-e DIFFICULTY=normal \
		-e OPS=ugerest \
		-e MAX_WORLD_SIZE=10000 \
		-e SNOOPER_ENABLED=false \
		-e SPAWN_PROTECTION=50 \
		-e TYPE=FABRIC \
		-e MODRINTH_PROJECTS=lithium,phosphor,chunky,fabric-api,cloth-config \
		-e MODS_FILE=/extras/mods.txt \
		-e DATAPACKS_FILE=/extras/datapacks.txt \
		-e MAX_MEMORY=5G \
		-e SYNC_SKIP_NEWER_IN_DESTINATION=false \
		-v $(PWD)/extras:/extras \
		-v $(PWD)/config:/config \
		-v $(PWD)/data:/data \
		-p 25565:25565 \
		--name mc \
		itzg/minecraft-server
