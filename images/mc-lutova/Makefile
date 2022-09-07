LATEST_SHA=$(shell git rev-parse HEAD)

clean:
	rm -r data/* data/.fabric data/.modrinth-files.manifest

image:
	docker build -t lutova .

tag: image
	docker tag lutova:latest gcr.io/stride-link/lutova:$(LATEST_SHA)
	docker tag lutova:latest gcr.io/stride-link/lutova:latest

release: tag
	docker push gcr.io/stride-link/lutova:$(LATEST_SHA)
	docker push gcr.io/stride-link/lutova:latest

list-images:
	gcloud container images list-tags gcr.io/stride-link/lutova

prune:
	docker container prune -f

serve: prune
	docker run \
		-e MAX_MEMORY=5G \
		-v $(PWD)/data:/data \
		-p 25565:25565 \
		--name mc \
		lutova

scale-down:
	kubectl scale --current-replicas=1 --replicas=0 statefulset/mc-lutova

scale-up:
	kubectl scale --current-replicas=0 --replicas=1 statefulset/mc-lutova
