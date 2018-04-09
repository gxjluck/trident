CA_CERT = ./secrets/ca.pem
ADMIN_KEY = ./secrets/admin-key.pem
ADMIN_CERT = ./secrets/admin.pem
MASTER_HOST = $(shell terraform output | grep -A1 master_ip | awk 'NR>1 {print $1}' | xargs echo)
SECRET_NAME ?= aws-ecr-cn-north-1

# Terraform
plan: tf_get
	terraform plan

apply: tf_get
	terraform apply

clean: tf_clean key_clean

output:
	terraform output

tf_get:
	terraform get

tf_clean: tf_get
	terraform destroy

# Ansible
ansible_build:
	terraform output > ./ansible/terraform-output
	python ./ansible/load.py
	cd ./ansible && ansible-playbook site.yml && cd ./..

# Secrets
key_clean:
	ls secrets | grep -v README  | sed "s/^/secrets\//" | xargs rm -rf

# Main build
build: apply ansible_build kubecfg sync_upload wait_for_kubectl_version kubectl_dockertoken create_all_addons build_complete

tmp: kubecfg sync_upload wait_for_kubectl_version kubectl_dockertoken create_all_addons build_complete

build_complete:
	osascript -e 'display notification "Your build has finished!" with title "Jobs Done"'

# Kubernetes
kubecfg:
	./cfssl/generate.sh client admin
	kubectl config set-cluster default-cluster \
	--server=https://$(MASTER_HOST) --certificate-authority=$(CA_CERT)
	kubectl config set-credentials default-admin \
	--certificate-authority=$(CA_CERT) --client-key=$(ADMIN_KEY) --client-certificate=$(ADMIN_CERT)
	kubectl config set-context default-system --cluster=default-cluster --user=default-admin
	kubectl config use-context default-system

remote_kubecfg: key_clean sync_download kubecfg

node_clean:
	kubectl get no | grep NotReady | awk '{print $$1}' | xargs kubectl delete node

kubectl_dockertoken:
	kubectl apply -f addons/ecr-dockercfg-refresh/ --validate=false

delete_kubectl_dockertoken:
	kubectl delete -f addons/ecr-dockercfg-refresh/
	kubectl delete secrets aws-ecr-cn-north-1
	kubectl delete secrets aws-ecr-cn-north-1 -n kube-system

delete_traefik:
	kubectl delete -f addons/traefik/

create_traefik:
	kubectl apply -f addons/traefik/

create_all_addons: create_essential_addons create_traefik

delete_all_addons: delete_essential_addons delete_traefik

delete_essential_addons:
	kubectl delete -f addons/dashboard/
	kubectl delete -f addons/dns/

create_essential_addons:
	until kubectl get secrets -n kube-system | grep $(SECRET_NAME) 2>/dev/null; do printf 'waiting on secret...\n'; sleep 5; done
	kubectl apply -f addons/dns/
	kubectl apply -f addons/dashboard/

sync_upload:
	aws s3 sync --exclude="admin*" --exclude="README.md" ./secrets/ s3://k8s-secrets
	aws s3 cp terraform.tfstate s3://k8s-secrets

sync_download:
	aws s3 sync s3://k8s-secrets ./secrets/
	cp ./secrets/terraform.tfstate terraform.tfstate

wait_for_kubectl_version:
	until kubectl get po 2>/dev/null; do printf 'waiting on kubectl...\n'; sleep 5; done

delete_secrets:
	kubectl delete secrets aws-ecr-cn-north-1
	kubectl delete secrets aws-ecr-cn-north-1 -n kube-system

traefik_ui:
	open http://localhost:8001/api/v1/namespaces/kube-system/services/traefik-web-ui:web/proxy/
