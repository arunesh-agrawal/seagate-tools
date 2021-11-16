

function print_hello()
{
    echo "Hello from LR cluster!!!"
}



function stop_hare() {
    ssh $PRIMARY_NODE 'hctl shutdown || true'    
}

function stop_pcs() {
#    ssh $PRIMARY_NODE 'pcs resource disable motr-ios-c{1,2}'
#    ssh $PRIMARY_NODE 'pcs resource disable s3server-c{1,2}-{1,2,3,4,5,6,7,8,9,10,11}'
#    sleep 30
    
    set +e
    ssh $PRIMARY_NODE 'hctl status'
    if [ $? -eq 0 ]; then
        ssh $PRIMARY_NODE 'cortx cluster stop --all'
    fi
    set -e
}

function stop_cluster() {
    echo "Stop cluster"

    case $HA_TYPE in
	"hare") stop_hare ;;
	"pcs") stop_pcs ;;
    esac
}

function cleanup_logs() {
    echo "Remove m0trace/addb/log files"

    pdsh -S -w $NODES "$SCRIPT_DIR/cleanup_addb_stobs.sh"
    pdsh -S -w $NODES "$SCRIPT_DIR/cleanup_trace_files.sh"

    # delete all text logs generated by s3server
    pdsh -S -w $NODES 'rm -rf /var/log/seagate/s3/s3server-*' || true

    echo "Remove /var/crash"
    pdsh -S -w $NODES "rm -rf /var/crash/*"
}

function restart_hare() {
    if [[ -n "$MKFS" ]]; then
        ssh $PRIMARY_NODE 'hctl bootstrap --mkfs /var/lib/hare/cluster.yaml'
    else
        ssh $PRIMARY_NODE 'hctl bootstrap /var/lib/hare/cluster.yaml'
    fi
    wait_for_cluster_start
    $SCRIPT_DIR/hostconfig.sh $NODES
     
}

function restart_pcs() {
    if [[ -n "$MKFS" ]]; then
#        ssh $PRIMARY_NODE "ssh srvnode-1 'systemctl start motr-mkfs@0x7200000000000001:0xc'"
#        ssh $PRIMARY_NODE "ssh srvnode-2 'systemctl start motr-mkfs@0x7200000000000001:0x55'"
        ssh $PRIMARY_NODE '/opt/seagate/cortx/hare/bin/hare_setup init --config "json:///opt/seagate/cortx_configs/provisioner_cluster.json"'
        pdsh -S -w $NODES 'systemctl start haproxy'
    fi

#    ssh $PRIMARY_NODE 'pcs resource enable motr-ios-c{1,2}'
#    ssh $PRIMARY_NODE 'pcs resource enable s3server-c{1,2}-{1,2,3,4,5,6,7,8,9,10,11}'
    ssh $PRIMARY_NODE 'cortx cluster start'
    wait_for_cluster_start
}

function restart_cluster() {
    echo "Restart cluster"
    $EX_SRV systemctl restart haproxy

    case $HA_TYPE in
	"hare") restart_hare ;;
	"pcs") restart_pcs ;;
    esac
}

function wait_for_cluster_start() {
    echo "wait for cluster start"

    while ! is_cluster_online $PRIMARY_NODE
    do
#        if _check_is_cluster_failed; then
#            _err "cluster is failed"
#            exit 1
#        fi
#
        sleep 5
    done
    
    $EX_SRV $SCRIPT_DIR/wait_s3_listeners.sh $S3SERVER
    sleep 300
}

function save_m0crate_artifacts()
{
    local m0crate_workdir="/tmp/m0crate_tmp"
    $EX_SRV "scp -r $m0crate_workdir/m0crate.*.log $PRIMARY_NODE:$(pwd)"
    $EX_SRV "scp -r $m0crate_workdir/test_io.*.yaml $PRIMARY_NODE:$(pwd)"
    
    if [[ -n $ADDB_DUMPS ]]; then
        $EX_SRV $SCRIPT_DIR/process_addb --host $(hostname) --dir $(pwd) \
            --app "m0crate" --m0crate-workdir $m0crate_workdir \
            --start $START_TIME --stop $STOP_TIME
    fi

    if [[ -n $M0TRACE_FILES ]]; then
        $EX_SRV $SCRIPT_DIR/save_m0traces $(hostname) $(pwd) "m0crate" "$m0crate_workdir"
    fi

    $EX_SRV "rm -rf $m0crate_workdir"
}

function save_cluster_status() {
    ssh $PRIMARY_NODE 'hctl status' > hctl-status.stop
}

function prepare_cluster() {
    echo ""
}

function collect_stat_data()
{
    # collecting pids of cortx (m0d/s3server/hax) applications
    $SCRIPT_DIR/../stat/collect_pids.sh $NODES pids.txt
}

function save_motr_artifacts() {
    local ios_m0trace_dir="m0trace_ios"
    local configs_dir="configs"
    local dumps_dir="dumps"

    # local variables for Hare cluster
    local ioservice_list=$(cat $RESULTS_DIR/hctl-status.stop \
        | grep ioservice | sed 's/\[.*\]//' | awk '{print $2}')

    local ios_l=""
    for zzz in $ioservice_list; do
        ios_l="$ios_l $zzz"
    done

    mkdir -p $configs_dir
    pushd $configs_dir
    for srv in $(echo $NODES | tr ',' ' '); do
        mkdir -p $srv
        scp -r $srv:/etc/sysconfig/motr ./$srv/
    done

    scp -r $PRIMARY_NODE:/var/lib/hare/cluster.yaml ./
    popd

    mkdir -p $ios_m0trace_dir
    pushd $ios_m0trace_dir
    if [[ -n $M0TRACE_FILES ]]; then
        $EX_SRV $SCRIPT_DIR/save_m0traces $(hostname) $(pwd) "motr" "\"$ios_l\""
    fi
    popd # $ios_motrace_dir

    mkdir -p $dumps_dir
    pushd $dumps_dir
    if [[ -n $ADDB_DUMPS ]]; then
        $EX_SRV $SCRIPT_DIR/process_addb --host $(hostname) --dir $(pwd) --app "motr" --io-services "\"$ios_l\"" --start $START_TIME --stop $STOP_TIME
    fi
    popd # $dumps_dir
}

function save_s3srv_artifacts() {
    local auth_dir="auth"
    local haproxy_dir="haproxy"
    local log_dir="log"
    local cfg_dir="cfg"
    local crash_dir="crash"

    for srv in $(echo $NODES | tr ',' ' '); do
        mkdir -p $srv
        pushd $srv

        # Fetch list of folders per server
        dirs=`ssh $srv -T "ls /var/log/seagate/motr/ | grep s3server | xargs -n1 basename"`
        echo $dirs
        mkdir $dirs

        for s3d in s3server*; do
            # Copy logs
            scp -r $srv:/var/log/seagate/s3/$s3d ./$s3d/$log_dir
        done

        mkdir -p $auth_dir
        scp -r $srv:/var/log/seagate/auth/* $auth_dir || true
        mv $auth_dir/server/app.log $auth_dir/server/app.$srv.log || true

        mkdir -p $haproxy_dir
        mkdir -p $haproxy_dir/$log_dir
        scp -r $srv:/var/log/haproxy* $haproxy_dir/$log_dir || true

        mkdir -p $haproxy_dir/$cfg_dir
        scp -r $srv:/etc/haproxy/* $haproxy_dir/$cfg_dir

        scp -r $srv:/opt/seagate/cortx/s3/conf/s3config.yaml ./
        scp -r $srv:/opt/seagate/cortx/s3/s3startsystem.sh ./
        scp -r $srv:/etc/hosts ./

        popd
    done

    if [[ -n $M0TRACE_FILES ]]; then
        $EX_SRV $SCRIPT_DIR/save_m0traces $(hostname) $(pwd) "s3server"
    fi

    if [[ -n $ADDB_DUMPS ]]; then
        $EX_SRV $SCRIPT_DIR/process_addb --host $(hostname) --dir $(pwd) --app "s3server" --start $START_TIME --stop $STOP_TIME
    fi
}

function collect_artifacts() {
    local m0d="m0d"
    local s3srv="s3server"
    local stats="stats"

    echo "Collect artifacts"

    mkdir -p $stats
    pushd $stats
    save_stats
    popd

    mkdir -p $m0d
    pushd $m0d
    save_motr_artifacts
    popd			# $m0d

    mkdir -p $s3srv
    pushd $s3srv
    save_s3srv_artifacts
    popd			# $s3server

    if [[ -n "$RUN_M0CRATE" ]]; then
        mkdir -p $M0CRATE_ARTIFACTS_DIR
        pushd $M0CRATE_ARTIFACTS_DIR
        save_m0crate_artifacts
        popd
    fi

    save_perf_results    
    
    if [[ -n $ADDB_DUMPS ]]; then

        local m0playdb_parts="$m0d/dumps/m0play* $s3srv/*/m0play*"

        if [[ -n "$RUN_M0CRATE" ]]; then
            if ls $M0CRATE_ARTIFACTS_DIR/m0play* &> /dev/null; then
                m0playdb_parts="$m0playdb_parts $M0CRATE_ARTIFACTS_DIR/m0play*"
            else
                echo "m0play not found"
            fi
        fi

        $SCRIPT_DIR/merge_m0playdb $m0playdb_parts
        rm -f $m0playdb_parts
        $SCRIPT_DIR/../../chronometry_v2/fix_reqid_collisions.py --fix-db --db ./m0play.db
    fi

    if [[ -n $ADDB_ANALYZE ]] && [[ -f "m0play.db" ]]; then
        local m0play_path="$(pwd)/m0play.db"
        local stats_addb="$stats/addb"
        mkdir -p $stats_addb
        pushd $stats_addb
        $SCRIPT_DIR/process_addb_data.sh --db $m0play_path
        popd
    fi

    if [[ "$STAT_COLLECTION" == *"GLANCES"* ]]; then
        pushd $stats
        local srv_nodes=$(echo $NODES | tr ',' ' ')
        $SCRIPT_DIR/artifacts_collecting/process_glances_data.sh $srv_nodes
        popd
    fi

    # generate structured form of stats
    $SCRIPT_DIR/../stat/gen_run_metadata.py -a $(pwd) -o run_metadata.json
}
