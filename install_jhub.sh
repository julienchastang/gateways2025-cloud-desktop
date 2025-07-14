# Adapted from https://github.com/zonca/jupyterhub-deploy-kubernetes-jetstream/

RELEASE=jhub
NAMESPACE=jhub

helm upgrade --install $RELEASE jupyterhub/jupyterhub \
      --namespace $NAMESPACE  \
      --create-namespace \
      --version 4.2.0 \
      --debug \
      --values values.yaml
