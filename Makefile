
CTX_PRIMARY=gke_aardvark-avalanche_europe-west4-c_dockerconeu-a
ctxprimary:
	kubectl config use-context ${CTX_PRIMARY}

CTX_SECONDARY=gke_aardvark-avalanche_europe-west4-c_dockerconeu-c
ctxsecondary:
	kubectl config use-context ${CTX_SECONDARY}

PRIMARY_DIR=./primary
SECONDARY_DIR=./secondary
COMMON_DIR=./common

# Top level targets
app: frontend backend
istio: istio.cluster-a istio.cluster-b coredns
clean: clean.app clean.istio

# App

frontend: frontend.a frontend.b
frontend.a:
	kubectl apply -f ${PRIMARY_DIR}/frontend.yaml --context ${CTX_PRIMARY}
frontend.b:
	kubectl apply -f ${SECONDARY_DIR}/frontend.yaml --context ${CTX_SECONDARY}

backend: backend.a backend.b
backend.a:
	kubectl apply -f ${PRIMARY_DIR}/backend.yaml --context ${CTX_PRIMARY}
backend.b:
	kubectl apply -f ${SECONDARY_DIR}/backend.yaml --context ${CTX_SECONDARY}

clean.app: clean.app.a clean.app.b
clean.app.a:
	kubectl delete -f ${PRIMARY_DIR} --context ${CTX_PRIMARY} || true
clean.app.b:
	kubectl delete -f ${SECONDARY_DIR} --context ${CTX_SECONDARY} || true

# Istio
HELM_VALUES=common/values-networks.yaml
$(HELM_VALUES):
	./bin/gen_mesh_networks ${CTX_PRIMARY} ${CTX_SECONDARY} bootstrap > $@

ISTIO_CHART=/Users/zackbutcher/src/istio-1.1.0-snapshot.3/install/kubernetes/helm/istio
ISTIO_YAML=common/istio-1_1-install.yaml
$(ISTIO_YAML): $(HELM_VALUES)
	helm template $(ISTIO_CHART) --name istio --namespace istio-system \
    	-f $(HELM_VALUES) > $@

istio.cluster-a: $(ISTIO_YAML)
	kubectl create namespace istio-system --context ${CTX_PRIMARY} || true
	kubectl label namespace default istio-injection=enabled --context ${CTX_PRIMARY} || true
	kubectl apply -f $(ISTIO_CHART)/templates/crds.yaml --context ${CTX_PRIMARY}
	kubectl delete secret cacerts -n istio-system --context ${CTX_PRIMARY} || true
	#kubectl create secret generic cacerts -n istio-system \
	#	--from-file=./certs/ca-cert.pem \
	#	--from-file=./certs/ca-key.pem \
	#	--from-file=./certs/root-cert.pem \
	#	--from-file=./certs/cert-chain.pem \
	#   --context ${CTX_PRIMARY}
	kubectl create secret generic cacerts -n istio-system \
		--from-file=istio-1.1.0-snapshot.3/samples/certs/ca-cert.pem \
		--from-file=istio-1.1.0-snapshot.3/samples/certs/ca-key.pem \
		--from-file=istio-1.1.0-snapshot.3/samples/certs/root-cert.pem \
		--from-file=istio-1.1.0-snapshot.3/samples/certs/cert-chain.pem \
		--context ${CTX_PRIMARY}
	kubectl apply -f $(ISTIO_YAML) --context ${CTX_PRIMARY}
	kubectl apply -f common/mtls-destinationrule.yaml --context ${CTX_PRIMARY}
istio.cluster-b: $(ISTIO_YAML)
	kubectl create namespace istio-system --context ${CTX_SECONDARY} || true
	kubectl label namespace default istio-injection=enabled --context ${CTX_SECONDARY} || true
	kubectl apply -f $(ISTIO_CHART)/templates/crds.yaml --context ${CTX_SECONDARY}
	kubectl delete secret cacerts -n istio-system --context ${CTX_SECONDARY} || true
#	kubectl create secret generic cacerts -n istio-system \
#		--from-file=./certs/ca-cert.pem \
#		--from-file=./certs/ca-key.pem \
#		--from-file=./certs/root-cert.pem \
#		--from-file=./certs/cert-chain.pem \
#		--context ${CTX_SECONDARY}
	kubectl create secret generic cacerts -n istio-system \
		--from-file=istio-1.1.0-snapshot.3/samples/certs/ca-cert.pem \
		--from-file=istio-1.1.0-snapshot.3/samples/certs/ca-key.pem \
		--from-file=istio-1.1.0-snapshot.3/samples/certs/root-cert.pem \
		--from-file=istio-1.1.0-snapshot.3/samples/certs/cert-chain.pem \
		--context ${CTX_SECONDARY}
	kubectl apply -f $(ISTIO_YAML) --context ${CTX_SECONDARY}
	kubectl apply -f common/mtls-destinationrule.yaml --context ${CTX_SECONDARY}

coredns: coredns.a coredns.b
coredns.a:
	./bin/coredns_config ${CTX_PRIMARY} | kubectl apply --context ${CTX_PRIMARY} -f - 
coredns.b:
	./bin/coredns_config ${CTX_SECONDARY} | kubectl apply --context ${CTX_SECONDARY} -f - 

clean.istio: clean.istio.a clean.istio.b
	rm -f $(HELM_VALUES) $(ISTIO_YAML)
clean.istio.a:
	kubectl delete ns istio-system --context ${CTX_PRIMARY} || true
	kubectl delete cm kube-dns -n kube-system --context ${CTX_PRIMARY} || true
	kubectl delete -f $(ISTIO_CHART)/templates/crds.yaml --context ${CTX_PRIMARY} || true
	kubectl delete destinationrule default --context ${CTX_PRIMARY} || true
	kubectl delete secret cacerts -n istio-system --context ${CTX_PRIMARY} || true
clean.istio.b:
	kubectl delete ns istio-system --context ${CTX_SECONDARY} || true
	kubectl delete cm kube-dns -n kube-system --context ${CTX_SECONDARY} || true
	kubectl delete -f $(ISTIO_CHART)/templates/crds.yaml --context ${CTX_SECONDARY} || true
	kubectl delete destinationrule default --context ${CTX_SECONDARY} || true
	kubectl delete secret cacerts -n istio-system --context ${CTX_SECONDARY} || true

# One time 
USER := $(shell gcloud config get-value core/account)
one-time-cluster-admin-setup:
	kubectl create clusterrolebinding cluster-admin-binding \
  		--clusterrole=cluster-admin \
  		--user="${USER}" \
		--context ${CTX_PRIMARY} || true
	kubectl create clusterrolebinding cluster-admin-binding \
  		--clusterrole=cluster-admin \
  		--user="${USER}" \
		--context ${CTX_SECONDARY} || true

ips:
	@echo waiting for public IPs to be assigned...
	@./bin/poll_external_ip ${CTX_PRIMARY} istio-ingressgateway
	@./bin/poll_external_ip ${CTX_SECONDARY} istio-ingressgateway
	@echo export PRIMARY_IP=$(shell kubectl get svc istio-ingressgateway -n istio-system -o=jsonpath='{.status.loadBalancer.ingress[0].ip}' --context ${CTX_PRIMARY})
	@echo export SECONDARY_IP=$(shell kubectl get svc istio-ingressgateway -n istio-system -o=jsonpath='{.status.loadBalancer.ingress[0].ip}' --context ${CTX_SECONDARY})