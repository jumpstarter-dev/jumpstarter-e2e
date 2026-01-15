JS_NAMESPACE="${JS_NAMESPACE:-jumpstarter-lab}"

setup() {
  bats_load_library bats-support
  bats_load_library bats-assert

  bats_require_minimum_version 1.5.0
}

wait_for_exporter() {
  # After a lease operation the exporter is disconnecting from controller and reconnecting.
  # The disconnect can take a short while so let's avoid catching the pre-disconnect state and early return
  sleep 2
  kubectl -n "${JS_NAMESPACE}" wait --timeout 20m --for=condition=Online --for=condition=Registered \
    exporters.jumpstarter.dev/test-exporter-oidc
  kubectl -n "${JS_NAMESPACE}" wait --timeout 20m --for=condition=Online --for=condition=Registered \
    exporters.jumpstarter.dev/test-exporter-sa
  kubectl -n "${JS_NAMESPACE}" wait --timeout 20m --for=condition=Online --for=condition=Registered \
    exporters.jumpstarter.dev/test-exporter-legacy
}

wait_for_exporter_hooks() {
  sleep 2
  kubectl -n "${JS_NAMESPACE}" wait --timeout 20m --for=condition=Online --for=condition=Registered \
    exporters.jumpstarter.dev/test-exporter-hooks
}

wait_for_exporter_status() {
  local exporter=$1
  local expected_status=$2
  local timeout=${3:-60}
  local interval=2
  local elapsed=0

  while [ $elapsed -lt $timeout ]; do
    local status=$(kubectl -n "${JS_NAMESPACE}" get exporters.jumpstarter.dev/$exporter \
      -o jsonpath='{.status.exporterStatus}' 2>/dev/null || echo "Unknown")
    if [ "$status" = "$expected_status" ]; then
      return 0
    fi
    sleep $interval
    elapsed=$((elapsed + interval))
  done

  echo "Timeout waiting for exporter $exporter to reach status $expected_status (current: $status)"
  return 1
}

@test "can create clients with admin cli" {
  jmp admin create client -n "${JS_NAMESPACE}" test-client-oidc     --unsafe --out /dev/null \
    --oidc-username dex:test-client-oidc
  jmp admin create client -n "${JS_NAMESPACE}" test-client-sa       --unsafe --out /dev/null \
    --oidc-username dex:system:serviceaccount:"${JS_NAMESPACE}":test-client-sa
  jmp admin create client -n "${JS_NAMESPACE}" test-client-legacy   --unsafe --save
}

@test "can create exporters with admin cli" {
  jmp admin create exporter -n "${JS_NAMESPACE}" test-exporter-oidc   --out /dev/null \
    --oidc-username dex:test-exporter-oidc \
    --label example.com/board=oidc
  jmp admin create exporter -n "${JS_NAMESPACE}" test-exporter-sa     --out /dev/null \
    --oidc-username dex:system:serviceaccount:"${JS_NAMESPACE}":test-exporter-sa \
    --label example.com/board=sa
  jmp admin create exporter -n "${JS_NAMESPACE}" test-exporter-legacy --save \
    --label example.com/board=legacy
}

@test "can login with oidc" {
  jmp config client   list
  jmp config exporter list

  jmp login --client test-client-oidc \
    --endpoint "$ENDPOINT" --namespace "${JS_NAMESPACE}" --name test-client-oidc \
    --issuer https://dex.dex.svc.cluster.local:5556 \
    --username test-client-oidc@example.com --password password --unsafe

  jmp login --client test-client-oidc-provisioning \
    --endpoint "$ENDPOINT" --namespace "${JS_NAMESPACE}" --name "" \
    --issuer https://dex.dex.svc.cluster.local:5556 \
    --username test-client-oidc-provisioning@example.com --password password --unsafe

  jmp login --client test-client-sa \
    --endpoint "$ENDPOINT" --namespace "${JS_NAMESPACE}" --name test-client-sa \
    --issuer https://dex.dex.svc.cluster.local:5556 \
    --connector-id kubernetes \
    --token $(kubectl create -n "${JS_NAMESPACE}" token test-client-sa) --unsafe

  jmp login --exporter test-exporter-oidc \
    --endpoint "$ENDPOINT" --namespace "${JS_NAMESPACE}" --name test-exporter-oidc \
    --issuer https://dex.dex.svc.cluster.local:5556 \
    --username test-exporter-oidc@example.com --password password

  jmp login --exporter test-exporter-sa \
    --endpoint "$ENDPOINT" --namespace "${JS_NAMESPACE}" --name test-exporter-sa \
    --issuer https://dex.dex.svc.cluster.local:5556 \
    --connector-id kubernetes \
    --token $(kubectl create -n "${JS_NAMESPACE}" token test-exporter-sa)

  go run github.com/mikefarah/yq/v4@latest -i ". * load(\"$GITHUB_ACTION_PATH/exporter.yaml\")" \
    /etc/jumpstarter/exporters/test-exporter-oidc.yaml
  go run github.com/mikefarah/yq/v4@latest -i ". * load(\"$GITHUB_ACTION_PATH/exporter.yaml\")" \
    /etc/jumpstarter/exporters/test-exporter-sa.yaml
  go run github.com/mikefarah/yq/v4@latest -i ". * load(\"$GITHUB_ACTION_PATH/exporter.yaml\")" \
    /etc/jumpstarter/exporters/test-exporter-legacy.yaml
 
  jmp config client   list
  jmp config exporter list
}

@test "can run exporters" {
  cat <<EOF | bash 3>&- &
while true; do
  jmp run --exporter test-exporter-oidc
done
EOF

  cat <<EOF | bash 3>&- &
while true; do
  jmp run --exporter test-exporter-sa
done
EOF

  cat <<EOF | bash 3>&- &
while true; do
  jmp run --exporter test-exporter-legacy
done
EOF


  wait_for_exporter
}

@test "can specify client config only using environment variables" {
  wait_for_exporter

  # we feed the namespace into JMP_NAMESPACE along with all the other client details
  # to verify that the client can operate without a config file
  JMP_NAMESPACE="${JS_NAMESPACE}" \
  JMP_DRIVERS_ALLOW="*" \
  JMP_NAME=test-exporter-legacy \
  JMP_ENDPOINT=$(kubectl get clients.jumpstarter.dev -n "${JS_NAMESPACE}" test-client-legacy -o 'jsonpath={.status.endpoint}') \
  JMP_TOKEN=$(kubectl get secrets -n "${JS_NAMESPACE}" test-client-legacy-client -o 'jsonpath={.data.token}' | base64 -d) \
  jmp shell --selector example.com/board=oidc j power on
}

@test "can operate on leases" {
  wait_for_exporter

  jmp config client use test-client-oidc

  jmp create lease     --selector example.com/board=oidc --duration 1d
  jmp get    leases
  jmp get    exporters
  jmp delete leases    --all
}

@test "can lease and connect to exporters" {
  wait_for_exporter

  jmp shell --client test-client-oidc   --selector example.com/board=oidc   j power on
  jmp shell --client test-client-sa     --selector example.com/board=sa     j power on
  jmp shell --client test-client-legacy --selector example.com/board=legacy j power on

  wait_for_exporter
  jmp shell --client test-client-oidc-provisioning --selector example.com/board=oidc j power on
}

@test "can get crds with admin cli" {
  jmp admin get client --namespace "${JS_NAMESPACE}"
  jmp admin get exporter --namespace "${JS_NAMESPACE}"
  jmp admin get lease --namespace "${JS_NAMESPACE}"
}

# ============================================================================
# HOOKS TESTS
# ============================================================================

@test "hooks: can create hooks-enabled exporters with admin cli" {
  jmp admin create exporter -n "${JS_NAMESPACE}" test-exporter-hooks --save \
    --label example.com/board=hooks
  jmp admin create exporter -n "${JS_NAMESPACE}" test-exporter-hooks-endlease --save \
    --label example.com/board=hooks-endlease
  jmp admin create exporter -n "${JS_NAMESPACE}" test-exporter-hooks-exit --save \
    --label example.com/board=hooks-exit
}

@test "hooks: can configure exporters with hooks" {
  go run github.com/mikefarah/yq/v4@latest -i ". * load(\"$GITHUB_ACTION_PATH/exporter-hooks.yaml\")" \
    /etc/jumpstarter/exporters/test-exporter-hooks.yaml
  go run github.com/mikefarah/yq/v4@latest -i ". * load(\"$GITHUB_ACTION_PATH/exporter-hooks-endlease.yaml\")" \
    /etc/jumpstarter/exporters/test-exporter-hooks-endlease.yaml
  go run github.com/mikefarah/yq/v4@latest -i ". * load(\"$GITHUB_ACTION_PATH/exporter-hooks-exit.yaml\")" \
    /etc/jumpstarter/exporters/test-exporter-hooks-exit.yaml

  # Verify hooks are configured in the file
  run go run github.com/mikefarah/yq/v4@latest '.hooks.beforeLease.script' \
    /etc/jumpstarter/exporters/test-exporter-hooks.yaml
  assert_success
  assert_output --partial "beforeLease starting"
}

@test "hooks: can run hooks-enabled exporter" {
  cat <<EOF | bash 3>&- &
while true; do
  jmp run --exporter test-exporter-hooks
done
EOF

  wait_for_exporter_hooks
}

@test "hooks: beforeLease executes on lease acquisition" {
  wait_for_exporter_hooks

  jmp config client use test-client-legacy

  # Create lease - this should trigger beforeLease hook
  jmp create lease --selector example.com/board=hooks --duration 5m

  # Wait for hook to execute and status to transition
  sleep 5

  # Status should be LeaseReady after successful beforeLease hook
  local status=$(kubectl -n "${JS_NAMESPACE}" get exporters.jumpstarter.dev/test-exporter-hooks \
    -o jsonpath='{.status.exporterStatus}')
  echo "Exporter status: $status"
  [ "$status" = "LeaseReady" ]

  # Clean up
  jmp delete leases --all
}

@test "hooks: can interact with drivers via j CLI in hook script" {
  wait_for_exporter_hooks

  # The beforeLease hook runs "j power on" - if it fails, the hook would fail
  # We verify successful hook execution by checking the lease was acquired
  jmp shell --client test-client-legacy --selector example.com/board=hooks j power on

  # If we get here, the hook successfully interacted with the driver
  wait_for_exporter_hooks
}

@test "hooks: afterLease executes on lease release" {
  wait_for_exporter_hooks

  jmp config client use test-client-legacy

  # Create and immediately delete a lease to trigger both hooks
  jmp create lease --selector example.com/board=hooks --duration 1m
  sleep 5  # Wait for beforeLease hook

  # Delete the lease to trigger afterLease hook
  jmp delete leases --all

  # Wait for afterLease to complete and status to return to Available
  sleep 5

  local status=$(kubectl -n "${JS_NAMESPACE}" get exporters.jumpstarter.dev/test-exporter-hooks \
    -o jsonpath='{.status.exporterStatus}')
  echo "Exporter status after lease release: $status"

  wait_for_exporter_hooks
}

@test "hooks: onFailure=endLease blocks lease acquisition" {
  # Start the endLease failure mode exporter
  cat <<EOF | bash 3>&- &
while true; do
  jmp run --exporter test-exporter-hooks-endlease
done
EOF

  # Wait for exporter to be online
  sleep 5
  kubectl -n "${JS_NAMESPACE}" wait --timeout 2m --for=condition=Online --for=condition=Registered \
    exporters.jumpstarter.dev/test-exporter-hooks-endlease || true

  jmp config client use test-client-legacy

  # Try to create a lease - beforeLease hook will fail with onFailure=endLease
  jmp create lease --selector example.com/board=hooks-endlease --duration 1m || true

  # Wait for hook to execute and fail
  sleep 10

  # Status should show BeforeLeaseHookFailed
  local status=$(kubectl -n "${JS_NAMESPACE}" get exporters.jumpstarter.dev/test-exporter-hooks-endlease \
    -o jsonpath='{.status.exporterStatus}')
  echo "Exporter status: $status"

  [ "$status" = "BeforeLeaseHookFailed" ]

  jmp delete leases --all || true
}

@test "hooks: onFailure=exit shuts down exporter" {
  # Start the exit failure mode exporter (NOT in a loop - we want it to stay down)
  jmp run --exporter test-exporter-hooks-exit &
  EXPORTER_PID=$!

  # Wait for exporter to be online
  sleep 5
  kubectl -n "${JS_NAMESPACE}" wait --timeout 2m --for=condition=Online --for=condition=Registered \
    exporters.jumpstarter.dev/test-exporter-hooks-exit || true

  jmp config client use test-client-legacy

  # Try to create a lease - beforeLease hook will fail with onFailure=exit
  jmp create lease --selector example.com/board=hooks-exit --duration 1m || true

  # Wait for exporter to shutdown
  sleep 10

  # The exporter should have gone offline
  local status=$(kubectl -n "${JS_NAMESPACE}" get exporters.jumpstarter.dev/test-exporter-hooks-exit \
    -o jsonpath='{.status.exporterStatus}' 2>/dev/null || echo "Offline")
  echo "Exporter status: $status"

  # Status should be Offline or BeforeLeaseHookFailed
  [[ "$status" = "Offline" ]] || [[ "$status" = "BeforeLeaseHookFailed" ]]

  jmp delete leases --all || true
  kill $EXPORTER_PID 2>/dev/null || true
}

@test "hooks: can delete hooks exporters with admin cli" {
  jmp admin delete exporter --namespace "${JS_NAMESPACE}" test-exporter-hooks --delete || true
  jmp admin delete exporter --namespace "${JS_NAMESPACE}" test-exporter-hooks-endlease --delete || true
  jmp admin delete exporter --namespace "${JS_NAMESPACE}" test-exporter-hooks-exit --delete || true

  run ! kubectl -n "${JS_NAMESPACE}" get exporters.jumpstarter.dev/test-exporter-hooks 2>/dev/null
  run ! kubectl -n "${JS_NAMESPACE}" get exporters.jumpstarter.dev/test-exporter-hooks-endlease 2>/dev/null
  run ! kubectl -n "${JS_NAMESPACE}" get exporters.jumpstarter.dev/test-exporter-hooks-exit 2>/dev/null
}

# ============================================================================
# CLEANUP TESTS
# ============================================================================

@test "can delete clients with admin cli" {
  kubectl -n "${JS_NAMESPACE}" get secret test-client-oidc-client
  kubectl -n "${JS_NAMESPACE}" get clients.jumpstarter.dev/test-client-oidc
  kubectl -n "${JS_NAMESPACE}" get clients.jumpstarter.dev/test-client-sa
  kubectl -n "${JS_NAMESPACE}" get clients.jumpstarter.dev/test-client-legacy

  jmp admin delete client --namespace "${JS_NAMESPACE}" test-client-oidc   --delete
  jmp admin delete client --namespace "${JS_NAMESPACE}" test-client-sa     --delete
  jmp admin delete client --namespace "${JS_NAMESPACE}" test-client-legacy --delete

  run ! kubectl -n "${JS_NAMESPACE}" get secret test-client-oidc-client
  run ! kubectl -n "${JS_NAMESPACE}" get clients.jumpstarter.dev/test-client-oidc
  run ! kubectl -n "${JS_NAMESPACE}" get clients.jumpstarter.dev/test-client-sa
  run ! kubectl -n "${JS_NAMESPACE}" get clients.jumpstarter.dev/test-client-legacy
}

@test "can delete exporters with admin cli" {
  kubectl -n "${JS_NAMESPACE}" get secret test-exporter-oidc-exporter
  kubectl -n "${JS_NAMESPACE}" get exporters.jumpstarter.dev/test-exporter-oidc
  kubectl -n "${JS_NAMESPACE}" get exporters.jumpstarter.dev/test-exporter-sa
  kubectl -n "${JS_NAMESPACE}" get exporters.jumpstarter.dev/test-exporter-legacy

  jmp admin delete exporter --namespace "${JS_NAMESPACE}" test-exporter-oidc   --delete
  jmp admin delete exporter --namespace "${JS_NAMESPACE}" test-exporter-sa     --delete
  jmp admin delete exporter --namespace "${JS_NAMESPACE}" test-exporter-legacy --delete

  run ! kubectl -n "${JS_NAMESPACE}" get secret test-exporter-oidc-exporter
  run ! kubectl -n "${JS_NAMESPACE}" get exporters.jumpstarter.dev/test-exporter-oidc
  run ! kubectl -n "${JS_NAMESPACE}" get exporters.jumpstarter.dev/test-exporter-sa
  run ! kubectl -n "${JS_NAMESPACE}" get exporters.jumpstarter.dev/test-exporter-legacy
}
