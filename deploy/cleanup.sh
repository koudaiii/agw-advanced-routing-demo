#!/usr/bin/env bash
# Deletes the demo resource group, which holds every resource that deploy.sh creates.
#   ./cleanup.sh            list the resources, then delete the group (asks for confirmation)
#   ./cleanup.sh --dry-run  list the resources and delete nothing
#   ./cleanup.sh --yes      delete without the confirmation prompt
# Deletion cannot be undone. It takes a few minutes and runs in the background.
set -euo pipefail

RG="${RG:-rg-agw-advrouting-demo}"
DRY_RUN=0
ASSUME_YES=0
case "${1:-}" in
  "") ;;
  --dry-run) DRY_RUN=1 ;;
  --yes) ASSUME_YES=1 ;;
  *) echo "unknown option: $1" >&2; exit 2 ;;
esac

if ! command -v az >/dev/null; then
  echo "az CLI not found" >&2; exit 1
fi
if [[ "$(az group exists -n "$RG")" != "true" ]]; then
  echo "resource group '$RG' does not exist; nothing to delete"; exit 0
fi

echo "subscription: $(az account show --query name -o tsv)"
echo "resource group: $RG"
az resource list -g "$RG" --query "[].{name:name, type:type}" -o table

if [[ $DRY_RUN -eq 1 ]]; then
  echo
  echo "Dry run: nothing deleted."
  exit 0
fi

if [[ $ASSUME_YES -eq 0 ]]; then
  if [[ ! -t 0 ]]; then
    echo "no terminal to confirm on; re-run with --yes to delete" >&2; exit 1
  fi
  echo
  echo "This deletes every resource above. It cannot be undone."
  read -r -p "Type the group name '$RG' to confirm: " answer
  if [[ "$answer" != "$RG" ]]; then echo "not confirmed; nothing deleted"; exit 1; fi
fi

az group delete -n "$RG" --yes --no-wait
echo "deletion started in the background (check with: az group exists -n $RG)"
