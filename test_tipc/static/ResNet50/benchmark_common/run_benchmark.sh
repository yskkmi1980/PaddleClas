#!/usr/bin/env bash
# Test training benchmark for a model.
# Usage：bash run_benchmark.sh ${model_item} ${bs_item} ${fp_item} ${run_mode} ${device_num}
function _set_params(){
    model_item=${1:-"model_item"}   # (必选) 模型 item
    base_batch_size=${2:-"2"}       # (必选) 如果是静态图单进程，则表示每张卡上的BS，需在训练时*卡数
    fp_item=${3:-"fp32"}            # (必选) fp32|fp16
    run_mode=${4:-"DP"}             # (必选) MP模型并行|DP数据并行|PP流水线并行|混合并行DP1-MP1-PP1|DP1-MP4-PP1
    device_num=${5:-"N1C1"}         # (必选) 使用的卡数量，N1C1|N1C8|N4C32 （4机32卡）
    profiling=${PROFILING:-"false"}      # (必选) Profiling  开关，默认关闭，通过全局变量传递
    model_repo="PaddleClas"          # (必选) 模型套件的名字
    speed_unit="samples/sec"         # (必选)速度指标单位
    skip_steps=10                  # (必选)解析日志，跳过模型前几个性能不稳定的step
    keyword="ips:"                 # (必选)解析日志，筛选出性能数据所在行的关键字
    convergence_key="loss:"        # (可选)解析日志，筛选出收敛数据所在行的关键字 如：convergence_key="loss:"
    max_epochs=${6:-"1"}           # （可选）需保证模型执行时间在5分钟内，需要修改代码提前中断的直接提PR 合入套件；或使用max_epoch参数
    num_workers=${7:-"4"}                  # (可选)
#   以下为通用执行命令，无特殊可不用修改
    model_name=${model_item}_bs${base_batch_size}_${fp_item}_${run_mode}  # (必填) 且格式不要改动,与竞品名称对齐
    device=${CUDA_VISIBLE_DEVICES//,/ }
    arr=(${device})
    num_gpu_devices=${#arr[*]}
    run_log_path=${TRAIN_LOG_DIR:-$(pwd)}  # （必填） TRAIN_LOG_DIR  benchmark框架设置该参数为全局变量
    profiling_log_path=${PROFILING_LOG_DIR:-$(pwd)}  # （必填） PROFILING_LOG_DIR benchmark框架设置该参数为全局变量
    speed_log_path=${LOG_PATH_INDEX_DIR:-$(pwd)}

    train_log_file=${run_log_path}/${model_repo}_${model_name}_${device_num}_log
    profiling_log_file=${profiling_log_path}/${model_repo}_${model_name}_${device_num}_profiling
    speed_log_file=${speed_log_path}/${model_repo}_${model_name}_${device_num}_speed
}
function _train(){
    batch_size=${base_batch_size}  # 如果模型跑多卡单进程时,请在_train函数中计算出多卡需要的bs
    echo "current CUDA_VISIBLE_DEVICES=${CUDA_VISIBLE_DEVICES}, model_name=${model_name}, device_num=${device_num}, is profiling=${profiling}"

    if [ ${fp_item} = "fp32" ]; then
        config_file="-c ppcls/configs/ImageNet/ResNet/ResNet50.yaml"
    elif [ ${fp_item} = "amp_fp16" ]; then
        config_file="-c ppcls/configs/ImageNet/ResNet/ResNet50_amp_O1_ultra.yaml"
    elif [ ${fp_item} = "pure_fp16" ]; then
    	config_file="-c ppcls/configs/ImageNet/ResNet/ResNet50_amp_O2_ultra.yaml"
    fi
    if [ ${profiling} = "false" ]; then
	profiling_config=""
	log_file=${train_log_file}
    else
	profiling_config="--profiler_options=\"batch_range=[10,20];state=GPU;tracer_option=Default;profile_path=model.profile\""
	log_file=${profiling_log_file}
    fi

    train_cmd="${config_file} -o DataLoader.Train.sampler.batch_size=${base_batch_size} -o Global.seed=1234 -o Global.epochs=${max_epochs} -o DataLoader.Train.loader.num_workers=${num_workers} ${profiling_config} -o Global.eval_during_train=False -o fuse_elewise_add_act_ops=True -o enable_addto=True"
#   以下为通用执行命令，无特殊可不用修改
    case ${run_mode} in
    DP) if [[ ${device_num} = "N1C1" ]];then
            echo "run ${run_mode} ${device_num}"
	        train_cmd="python ppcls/static/train.py ${train_cmd}"
        else
            rm -rf ./mylog
            train_cmd="python -m paddle.distributed.launch --gpus 0,1,2,3,4,5,6,7 ppcls/static/train.py ${train_cmd}"
        fi
        ;;
    DP1-MP1-PP1)  echo "run run_mode: DP1-MP1-PP1" ;;
    *) echo "choose run_mode "; exit 1;
    esac

    echo "train_cmd: ${train_cmd}  log_file: ${log_file}"
    timeout 10m ${train_cmd} > ${log_file} 2>&1
    if [ $? -ne 0 ];then
        echo -e "${model_name}, FAIL"
    else
        echo -e "${model_name}, SUCCESS"
    fi
    # kill -9 `ps -ef|grep 'python'|awk '{print $2}'`
    if [ ${device_num} != "N1C1" -a -d mylog ]; then
        rm ${log_file}
        cp mylog/workerlog.0 ${log_file}
    fi
    cd ../
}

function _set_env(){
    export FLAGS_fraction_of_gpu_memory_to_use=0.80
    export FLAGS_cudnn_batchnorm_spatial_persistent=1
    export FLAGS_max_inplace_grad_add=8
    export FLAGS_cudnn_exhaustive_search=1
    export FLAGS_eager_delete_tensor_gb=0.0
    export FLAGS_conv_workspace_size_limit=4000
    export FLAGS_apply_pass_to_program=true
}


source ${BENCHMARK_ROOT}/scripts/run_model.sh   # 在该脚本中会对符合benchmark规范的log使用analysis.py 脚本进行性能数据解析;如果不联调只想要产出训练log可以注掉本行,提交时需打开
_set_params $@
# _train       # 如果只产出训练log,不解析,可取消注释
_set_env
_run     # 该函数在run_model.sh中,执行时会调用_train; 如果不联调只产出训练log可以注掉本行,提交时需打开
