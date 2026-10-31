#!/bin/bash
# shellcheck disable=SC2250,SC2086,SC2312,SC2027,SC2034,SC2154

REMAKE_FALSE='.locals 1
    invoke-static {}, Lcom/android/internal/util/HookHelper;->RETURN_FALSE()Z
    move-result v0
    return v0'

REMAKE_TRUE='.locals 1
    invoke-static {}, Lcom/android/internal/util/HookHelper;->RETURN_TRUE()Z
    move-result v0
    return v0'

REMAKE_VOID='.locals 0
    return-void'

INVOKE_TRUE="invoke-static {}, Lcom/android/internal/util/HookHelper;->RETURN_TRUE()Z"

PRELOADS_SHAREDUIDS='.locals 1
    invoke-static {}, Lcom/android/internal/util/HookHelper;->RETURN_TRUE()Z
    move-result v0
    sput-boolean v0, Lcom/android/server/pm/ReconcilePackageUtils;->ALLOW_NON_PRELOADS_SYSTEM_SHAREDUIDS:Z
    return-void'

# Keep the helper under the remote repository's existing bin/ tree.  The
# refactored worktree used utils/smalikit.py, but adding a new top-level utils/
# directory would change the online repository layout.
smali_kit="python3 bin/smalikit.py"

_port::lower() {
    printf '%s' "${1:-}" | tr '[:upper:]' '[:lower:]'
}

# Define color output function
error() {
    [[ -n "${PORT_LOG_FILE:-}" ]] && printf '[%s] [ERR] %s\n' "$(date +%Y-%m-%dT%H:%M:%S%z)" "$*" >> "${PORT_LOG_FILE}" 2>/dev/null
    if [ "$#" -eq 2 ]; then

        if [[ "$LANG" == zh_CN* ]]; then
            echo -e \[$(date +%m%d-%T)\] "\033[1;31m"$1"\033[0m"
        elif [[ "$LANG" == en* ]]; then
            echo -e \[$(date +%m%d-%T)\] "\033[1;31m"$2"\033[0m"
        else
            echo -e \[$(date +%m%d-%T)\] "\033[1;31m"$2"\033[0m"
        fi
    elif [ "$#" -eq 1 ]; then
        echo -e \[$(date +%m%d-%T)\] "\033[1;31m"$1"\033[0m"
    else
        echo "Usage: error <Chinese> <English>"
    fi
    return 1
}

yellow() {
    [[ -n "${PORT_LOG_FILE:-}" ]] && printf '[%s] [WARN] %s\n' "$(date +%Y-%m-%dT%H:%M:%S%z)" "$*" >> "${PORT_LOG_FILE}" 2>/dev/null
    if [ "$#" -eq 2 ]; then

        if [[ "$LANG" == zh_CN* ]]; then
            echo -e \[$(date +%m%d-%T)\] "\033[1;33m"$1"\033[0m"
        elif [[ "$LANG" == en* ]]; then
            echo -e \[$(date +%m%d-%T)\] "\033[1;33m"$2"\033[0m"
        else
            echo -e \[$(date +%m%d-%T)\] "\033[1;33m"$2"\033[0m"
        fi
    elif [ "$#" -eq 1 ]; then
        echo -e \[$(date +%m%d-%T)\] "\033[1;33m"$1"\033[0m"
    else
        echo "Usage: yellow <Chinese> <English>"
    fi
}

blue() {
    [[ -n "${PORT_LOG_FILE:-}" ]] && printf '[%s] [INFO] %s\n' "$(date +%Y-%m-%dT%H:%M:%S%z)" "$*" >> "${PORT_LOG_FILE}" 2>/dev/null
    if [ "$#" -eq 2 ]; then

        if [[ "$LANG" == zh_CN* ]]; then
            echo -e \[$(date +%m%d-%T)\] "\033[1;34m"$1"\033[0m"
        elif [[ "$LANG" == en* ]]; then
            echo -e \[$(date +%m%d-%T)\] "\033[1;34m"$2"\033[0m"
        else
            echo -e \[$(date +%m%d-%T)\] "\033[1;34m"$2"\033[0m"
        fi
    elif [ "$#" -eq 1 ]; then
        echo -e \[$(date +%m%d-%T)\] "\033[1;34m"$1"\033[0m"
    else
        echo "Usage: blue <Chinese> <English>"
    fi
}

green() {
    [[ -n "${PORT_LOG_FILE:-}" ]] && printf '[%s] [INFO] %s\n' "$(date +%Y-%m-%dT%H:%M:%S%z)" "$*" >> "${PORT_LOG_FILE}" 2>/dev/null
    if [ "$#" -eq 2 ]; then
        if [[ "$LANG" == zh_CN* ]]; then
            echo -e \[$(date +%m%d-%T)\] "\033[1;32m"$1"\033[0m"
        elif [[ "$LANG" == en* ]]; then
            echo -e \[$(date +%m%d-%T)\] "\033[1;32m"$2"\033[0m"
        else
            echo -e \[$(date +%m%d-%T)\] "\033[1;32m"$2"\033[0m"
        fi
    elif [ "$#" -eq 1 ]; then
        echo -e \[$(date +%m%d-%T)\] "\033[1;32m"$1"\033[0m"
    else
        echo "Usage: green <Chinese> <English>"
    fi
}

#Check for the existence of the requirements command, proceed if it exists, or abort otherwise.
exists() {
    command -v "$1" > /dev/null 2>&1
}

abort() {
    error "--> Missing $1 abort! please run ./setup.sh first"
    error "--> 命令 $1 缺失!请重新运行setup.sh"
    exit 1
}

check() {
    for b in "$@"; do
        exists "$b" || abort "$b"
    done
}

# Legacy single-smali patch entry point retained for device overrides that
# predate the apk_decode/apk_build backend wrappers.  It now validates every
# intermediate command and keeps the original APK until the rebuilt artifact
# has been aligned and signed successfully.
patch_smali() {
    local artifact_name="${1:-}"
    local smali_name="${2:-}"
    local search_pattern="${3:-}"
    local replacement_pattern="${4:-}"
    local mode="${5:-}"
    local target_file
    local target_name
    local folder_name
    local work
    local dex_file
    local smali_dir
    local target_smali
    local baksmali_command
    local smali_command

    [[ -n "${artifact_name}" && -n "${smali_name}" ]] || return 2
    target_file="$(find "${work_dir:-.}/build/portrom/images" -type f -name "${artifact_name}" -print -quit 2>/dev/null)"
    if [[ ! -f "${target_file}" ]]; then
        error "找不到 ${artifact_name}，请手动检查" "Failed to find ${artifact_name}; check it manually"
        return 1
    fi
    target_name="$(basename "${target_file}")"
    folder_name="${target_name%.*}"
    work="${work_dir:-.}/tmp/${folder_name}"
    rm -rf -- "${work}"
    mkdir -p "${work}" || return 1
    cp -p -- "${target_file}" "${work}/${target_name}" || return 1
    if [[ "${is_eu_rom:-false}" == true ]]; then
        smali_command="java -jar bin/apktool/smali-3.0.5.jar"
        baksmali_command="java -jar bin/apktool/baksmali-3.0.5.jar"
    else
        smali_command="java -jar bin/apktool/smali.jar"
        baksmali_command="java -jar bin/apktool/baksmali.jar"
    fi
    7z x -y "${work}/${target_name}" '*.dex' -o"${work}" >/dev/null || return 1
    shopt -s nullglob
    for dex_file in "${work}"/*.dex; do
        smali_dir="${dex_file%.dex}"
        "${baksmali_command%% *}" ${baksmali_command#* } d --api "${port_android_sdk:-35}" "${dex_file}" -o "${smali_dir}" >/dev/null 2>&1 || return 1
    done
    shopt -u nullglob
    target_smali="$(find "${work}" -type f -path "*/${smali_name}" -print -quit 2>/dev/null)"
    [[ -f "${target_smali}" ]] || { error "未找到 Smali 目标 ${smali_name}" "Smali target ${smali_name} not found"; return 1; }
    if [[ "${mode}" == regex ]]; then
        sed -i "/${search_pattern}/c\\${replacement_pattern}" "${target_smali}" || return 1
    else
        sed -i "s/${search_pattern}/${replacement_pattern}/g" "${target_smali}" || return 1
    fi
    for smali_dir in "${work}"/classes*; do
        [[ -d "${smali_dir}" ]] || continue
        "${smali_command%% *}" ${smali_command#* } a --api "${port_android_sdk:-35}" "${smali_dir}" -o "${smali_dir}.dex" >/dev/null 2>&1 || return 1
        (cd "${work}" && 7z d -y "${target_name}" "$(basename "${smali_dir}").dex" >/dev/null 2>&1 || true)
        (cd "${work}" && 7z a -y -mx0 -tzip "${target_name}" "$(basename "${smali_dir}").dex" >/dev/null 2>&1) || return 1
    done
    if [[ "${target_name}" == *.apk ]]; then
        zipalign -p -f 4 "${work}/${target_name}" "${target_file}.new" >/dev/null 2>&1 || return 1
        apksigner sign --key otatools/key/testkey.pk8 --cert otatools/key/testkey.x509.pem "${target_file}.new" >/dev/null 2>&1 || return 1
        apksigner verify "${target_file}.new" >/dev/null 2>&1 || return 1
        mv -f -- "${target_file}.new" "${target_file}" || return 1
    else
        cp -p -- "${work}/${target_name}" "${target_file}" || return 1
    fi
    return 0
}

shopt -s expand_aliases
if [[ "$OSTYPE" == "darwin"* ]]; then
    yellow "检测到Mac，设置alias" "macOS detected,setting alias"
    alias sed=gsed
    alias tr=gtr
    alias grep=ggrep
    alias du=gdu
    alias date=gdate
    alias stat=gstat
    alias find=gfind
fi

# Decode backend: apkeditor | apktool
APK_BACKEND="${APK_BACKEND:-apktool}"
# Optional per-artifact override rules (comma-separated).
# Example:
# APK_BACKEND_OVERRIDES="framework.jar=apktool,services.jar=apktool,SystemUI.apk=apkeditor"
APK_BACKEND_OVERRIDES="${APK_BACKEND_OVERRIDES:-}"
# Built-in safe defaults for APKs that often fail with apktool resource rebuild.
# User rules in APK_BACKEND_OVERRIDES take precedence.
APK_BACKEND_DEFAULT_OVERRIDES="${APK_BACKEND_DEFAULT_OVERRIDES:-OplusLauncher.apk=apkeditor,SystemUI.apk=apkeditor,Aod.apk=apkeditor,AIUnit.apk=apkeditor,HeyTapSpeechAssist.apk=apkeditor,OppoGallery2.apk=apkeditor,Battery.apk=apkeditor,Settings.apk=apkeditor}"

resolve_backend_for_artifact() {
    local default_backend
    default_backend="$(_port::lower "${1:-}")"
    local artifact="$2"
    local rules="${APK_BACKEND_OVERRIDES}"
    local default_rules="${APK_BACKEND_DEFAULT_OVERRIDES}"
    local rule=""

    [[ -z "${artifact}" ]] && { echo "${default_backend}"; return; }

    if [[ -n "${rules}" ]]; then
        IFS=',' read -r -a _backend_rules <<< "${rules}"
        for rule in "${_backend_rules[@]}"; do
            local key="${rule%%=*}"
            local val="${rule#*=}"
            [[ -z "${key}" || -z "${val}" ]] && continue
            if [[ "${artifact}" == "${key}" ]]; then
                _port::lower "${val}"
                return
            fi
        done
    fi

    if [[ -n "${default_rules}" ]]; then
        IFS=',' read -r -a _default_backend_rules <<< "${default_rules}"
        for rule in "${_default_backend_rules[@]}"; do
            local key="${rule%%=*}"
            local val="${rule#*=}"
            [[ -z "${key}" || -z "${val}" ]] && continue
            if [[ "${artifact}" == "${key}" ]]; then
                _port::lower "${val}"
                return
            fi
        done
    fi

    echo "${default_backend}"
}

normalize_decode_layout() {
    local decoded_dir="$1"
    # Keep decode tree clean for apktool build. Symlinks under smali/
    # can be recursively picked up by apktool and cause classes.dex overflow.
    # If old compatibility links exist, remove them.
    if [[ -d "${decoded_dir}/smali" ]]; then
        find "${decoded_dir}/smali" -maxdepth 1 -type l -name "classes*" -exec rm -f {} \;
    fi
}

get_smali_class_dirs() {
    local decoded_dir="$1"
    local classes_dir=""

    # APKEditor style
    for classes_dir in "${decoded_dir}"/smali/classes*; do
        [[ -d "${classes_dir}" ]] && printf '%s\n' "${classes_dir}"
    done

    # apktool primary smali dir
    if [[ -d "${decoded_dir}/smali" ]]; then
        printf '%s\n' "${decoded_dir}/smali"
    fi

    # apktool extra dex dirs
    for classes_dir in "${decoded_dir}"/smali_classes*; do
        [[ -d "${classes_dir}" ]] && printf '%s\n' "${classes_dir}"
    done | awk '!seen[$0]++'
}

apk_decode() {
    local input_file="$1"
    local output_dir="$2"
    shift 2
    local backend
    backend="$(_port::lower "${APK_BACKEND:-}")"
    local artifact=""
    local args=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --backend)
                backend="$(_port::lower "${2:-}")"
                shift 2
                ;;
            --artifact)
                artifact="$2"
                shift 2
                ;;
            *)
                args+=("$1")
                shift
                ;;
        esac
    done

    backend="$(resolve_backend_for_artifact "${backend}" "${artifact}")"

    case "${backend}" in
        apktool)
            local apktool_args=()
            local i=0
            while [[ ${i} -lt ${#args[@]} ]]; do
                case "${args[i]}" in
                    -framework)
                        # Skip value after -framework as well.
                        ((i+=2))
                        continue
                        ;;
                    -p)
                        # apktool supports -p; keep pair
                        apktool_args+=("${args[i]}")
                        if [[ $((i + 1)) -lt ${#args[@]} ]]; then
                            apktool_args+=("${args[i+1]}")
                        fi
                        ((i+=2))
                        continue
                        ;;
                    -no-dex-debug)
                        apktool_args+=(--no-debug-info)
                        ((i+=1))
                        continue
                        ;;
                    *)
                        apktool_args+=("${args[i]}")
                        ((i+=1))
                        ;;
                esac
            done
            java -jar bin/apktool/apktool.jar d -f "${input_file}" -o "${output_dir}" "${apktool_args[@]}" || return 1
            ;;
        apkeditor|*)
            java -jar bin/apktool/APKEditor.jar d -f -i "${input_file}" -o "${output_dir}" "${args[@]}" || return 1
            ;;
    esac

    normalize_decode_layout "${output_dir}"
}

apk_build() {
    local input_dir="$1"
    local output_file="$2"
    shift 2
    local backend
    backend="$(_port::lower "${APK_BACKEND:-}")"
    local artifact=""
    local args=()

    while [[ $# -gt 0 ]]; do
        case "$1" in
            --backend)
                backend="$(_port::lower "${2:-}")"
                shift 2
                ;;
            --artifact)
                artifact="$2"
                shift 2
                ;;
            *)
                args+=("$1")
                shift
                ;;
        esac
    done

    backend="$(resolve_backend_for_artifact "${backend}" "${artifact}")"

    case "${backend}" in
        apktool)
            local apktool_args=()
            local i=0
            while [[ ${i} -lt ${#args[@]} ]]; do
                case "${args[i]}" in
                    -framework)
                        # APKEditor-only option; apktool backend ignores it.
                        ((i+=2))
                        continue
                        ;;
                    *)
                        apktool_args+=("${args[i]}")
                        ((i+=1))
                        ;;
                esac
            done
            java -jar bin/apktool/apktool.jar b -f "${input_dir}" -o "${output_file}" "${apktool_args[@]}" || return 1
            ;;
        apkeditor|*)
            java -jar bin/apktool/APKEditor.jar b -f -i "${input_dir}" -o "${output_file}" "${args[@]}" || return 1
            ;;
    esac
}



extract_partition() {
    part_img=$1
    part_name=$(basename ${part_img})
    target_dir=$2
    if [[ ! -f ${part_img} ]]; then
        error "找不到分区镜像 ${part_img}" "Partition image ${part_img} is missing."
        return 1
    fi
    if [[ $($tools_dir/gettype -i ${part_img} ) == "ext" ]];then
        blue "[ext] 正在分解${part_name}" "[ext] Extracing ${part_name} "
        python3 bin/imgextractor/imgextractor.py ${part_img} ${target_dir}  || { error "分解 ${part_name} 失败" "Extracting ${part_name} failed."; exit 1; }
        green "[ext]分解[${part_name}] 完成" "[ext] ${part_name} extracted."
        rm -rf ${part_img}
    elif [[ $($tools_dir/gettype -i ${part_img}) == "erofs" ]]; then
        blue "[erofs] 正在分解${part_name} " "[erofs] Extracing ${part_name} "
        extract.erofs -x -i ${part_img}  -o $target_dir > /dev/null 2>&1 || { error "分解 ${part_name} 失败" "Extracting ${part_name} failed." ; exit 1; }
        green "[erofs] 分解[${part_name}] 完成" "[erofs] ${part_name} extracted."
        rm -rf ${part_img}
    else
        error "无法识别img文件类型，请检查" "Unable to handle img, exit."
        exit 1
    fi
}

disable_avb_verify() {
    fstab=$(find $1 -name "fstab*")
    if [[ $fstab == "" ]];then
        error "未找到 fstab 文件！" "No fstab found!"
        sleep 5
    else
        blue "禁用 AVB 验证中..." "Disabling AVB verfication...."
        for file in $fstab; do
            sed -i 's/,avb.*system//g' $file
            sed -i 's/,avb,/,/g' $file
            sed -i 's/,avb=.*a,/,/g' $file
            sed -i 's/,avb_keys.*key//g' $file
            if [[ "${pack_type}" == "EXT" ]];then
                sed -i "/erofs/d" $file
            fi
        done
        blue "AVB 验证禁用完成" "AVB verification disabled successfully"
    fi
}
spoof_bootimg() {
    bootimg=$1
    mkdir -p ${work_dir}/tmp/boot_official
    cp $bootimg ${work_dir}/tmp/boot_official/boot.img
    pushd "${work_dir}/tmp/boot_official" || return 1
    magiskboot unpack -h ${work_dir}/tmp/boot_official/boot.img > /dev/null 2>&1
    sed -i '/^cmdline=/ s/$/ androidboot.vbmeta.device_state=unlocked/' header
    magiskboot repack ${work_dir}/tmp/boot_official/boot.img  ${work_dir}/tmp/boot_official/new-boot.img
    popd
    cp ${work_dir}/tmp/boot_official/new-boot.img $bootimg
}



patch_kernel() {
    kernel_file=$1
    dtb_file=$2
    bootimg_name=$3
    echo ">> patch_kernel() started ..."
    local tmp_dir="${work_dir}/tmp/patch"
    mkdir -p "${tmp_dir}" || { error "无法创建临时目录 ${tmp_dir}"; exit 1; }
    cd "${tmp_dir}" || { error "无法进入 ${tmp_dir}"; exit 1; }

    #############################
    ### 1. Patch boot.img ###
    blue "查找 boot.img" "Looking under ${work_dir}/build/baserom/"
    local bootimg
    bootimg=$(find "${work_dir}/build/baserom/" -name boot.img | head -n 1)
    if [[ -z "$bootimg" ]]; then
        error "未找到 boot.img"
        exit 1
    fi
    cp "$bootimg" boot.img

    blue "解包 boot.img" "调用 magiskboot unpack"
    if ! magiskboot unpack -h boot.img > /dev/null 2>&1; then
        error "解包 boot.img 失败"
        exit 1
    fi

    # Handle ramdisk.cpio (when present).
    if [ -f ramdisk.cpio ]; then
        local comp
        comp=$(magiskboot decompress ramdisk.cpio | grep -v 'raw' | sed -n 's;.*\[\(.*\)\];\1;p')
        if [ -n "$comp" ]; then
            mv -f ramdisk.cpio ramdisk.cpio."$comp"
            if ! magiskboot decompress ramdisk.cpio."$comp" ramdisk.cpio > /dev/null 2>&1 && $comp --help > /dev/null 2>&1; then
                $comp -dc ramdisk.cpio."$comp" > ramdisk.cpio
            fi
        fi
        mkdir -p ramdisk
        chmod 755 ramdisk
        cd ramdisk || { error "无法进入 ramdisk 目录"; exit 1; }
        EXTRACT_UNSAFE_SYMLINKS=1 cpio -d -F ../ramdisk.cpio -i > /dev/null 2>&1
        cd .. || return 1
    fi

    # Disable AVB verification.
    disable_avb_verify "${tmp_dir}/"

    # Replace the kernel image.
    blue "替换 kernel" "复制新内核文件到临时目录"
    cp -f "$kernel_file" "${tmp_dir}/kernel"

    # Replace the dtb when one was unpacked (Android 10 and earlier).
    if [[ -f dtb ]] && [[ -n $dtb_file ]]; then
        blue "检测到 dtb 文件" "替换 boot.img 中的 dtb 文件"
        cp -fv "$dtb_file" "${tmp_dir}/dtb"
    fi

    # Check the ramdisk for fstab files (fstab.qcom, fstab.default, fstab.emmc).
    if [ -d ramdisk ]; then
        for f in fstab.qcom fstab.default fstab.emmc; do
            if [ -f "ramdisk/${f}" ]; then
                yellow "检测到" "${tmp_dir}/ramdisk/${f} 存在，无需额外处理"
                if [[ $convert_to_aonly == true ]];then
                    yellow "修改${f}转为A-only"
                    sed -i "/,slotselect/d" ramdisk/${f}
                fi
            fi
        done
    fi

    # Repack the ramdisk (when present).
    if [ -d ramdisk ]; then
        cd ramdisk || { error "无法进入 ramdisk 目录"; exit 1; }
        find . | sed 1d | cpio -H newc -R 0:0 -o -F ../ramdisk_new.cpio > /dev/null 2>&1
        cd .. || return 1
        if [ -n "$comp" ]; then
            if ! magiskboot compress=$comp ramdisk_new.cpio > /dev/null 2>&1 && $comp --help > /dev/null 2>&1; then
                $comp -9c ramdisk_new.cpio > ramdisk.cpio."$comp"
            fi
        fi
        local ramdisk_file
        ramdisk_file=$(ls ramdisk_new.cpio* | tail -n1)
        [ -n "$ramdisk_file" ] && cp -f "$ramdisk_file" ramdisk.cpio
    fi

    # Set repack flags based on the compression tool.
    local nocompflag=""
    case $comp in
        cpio) nocompflag="-n" ;;
    esac

    blue "重打包 boot.img" "生成新 boot 镜像"
    if ! magiskboot repack $nocompflag boot.img "${work_dir}/devices/${base_product_device}/${bootimg_name}"; then
        error "重打包 boot.img 失败"
        exit 1
    fi

    #############################
    ### 2. Patch vendor_boot.img (when present) ###
    local vendor_boot
    vendor_boot=$(find "${work_dir}/build/baserom/" -name vendor_boot.img | head -n 1)
    if [ -n "$vendor_boot" ]; then
        blue "检测到 vendor_boot.img 开始处理 vendor_boot 镜像" "vendor_boot detected, patching..."
        vendor_boot_tmp=$tmp_dir/vendor_boot_tmp
        mkdir -p $vendor_boot_tmp || { error "无法创建 vendor_tmp 目录"; exit 1; }
        cp "$vendor_boot" $vendor_boot_tmp/vendor_boot.img
        cd "$vendor_boot_tmp" || return 1
        if ! magiskboot unpack -h vendor_boot.img > /dev/null 2>&1; then
            error "解包 vendor_boot.img 失败"
            exit 1
        fi

        # Handle vendor_boot's ramdisk.cpio (when present).
        if [ -f ramdisk.cpio ]; then
            local vcomp
            vcomp=$(magiskboot decompress ramdisk.cpio | grep -v 'raw' | sed -n 's;.*\[\(.*\)\];\1;p')
            if [ -n "$vcomp" ]; then
                mv -f ramdisk.cpio ramdisk.cpio."$vcomp"
                if ! magiskboot decompress ramdisk.cpio."$vcomp" ramdisk.cpio > /dev/null 2>&1 && $vcomp --help > /dev/null 2>&1; then
                    $vcomp -dc ramdisk.cpio."$vcomp" > ramdisk.cpio
                fi
            fi
            mkdir -p ramdisk
            chmod 755 ramdisk
            cd ramdisk || { error "无法进入 vendor ramdisk 目录"; exit 1; }
            EXTRACT_UNSAFE_SYMLINKS=1 cpio -d -F ../ramdisk.cpio -i > /dev/null 2>&1
            cd .. || return 1
        fi

        # Replace the dtb inside vendor_boot (when present).
        if [ -f dtb ]; then
            blue "替换 dtb 文件" "Replacing dtb"
            cp -fv "$dtb_file" "${vendor_boot_tmp}/dtb"
        fi

        # Check the vendor_boot ramdisk for fstab files.
        if [ -d ramdisk ]; then
            for f in fstab.qcom fstab.default fstab.emmc; do
                if [ -f "ramdisk/${f}" ]; then
                    yellow "检测到" "${vendor_boot_tmp}/ramdisk/${f} 存在，无需额外处理"
                fi
            done
        fi

        # Repack vendor_boot's ramdisk (when present).
        if [ -d ramdisk ]; then
            cd ramdisk || { error "无法进入 vendor ramdisk 目录"; exit 1; }
            find . | sed 1d | cpio -H newc -R 0:0 -o -F ../ramdisk_new.cpio > /dev/null 2>&1
            cd .. || return 1
            if [ -n "$vcomp" ]; then
                if ! magiskboot compress=$vcomp ramdisk_new.cpio > /dev/null 2>&1 && $vcomp --help > /dev/null 2>&1; then
                    $vcomp -9c ramdisk_new.cpio > ramdisk.cpio."$vcomp"
                fi
            fi
            local vramdisk
            vramdisk=$(ls ramdisk_new.cpio* | tail -n1)
            [ -n "$vramdisk" ] && cp -f "$vramdisk" ramdisk.cpio
        fi

        local v_nocompflag=""
        case $vcomp in
            cpio) v_nocompflag="-n" ;;
        esac
        blue "重打包 vendor_boot.img" "Repacking vendor_boot.img"
        if ! magiskboot repack $v_nocompflag vendor_boot.img "${work_dir}/devices/${base_product_device}/vendor_boot.img" > /dev/null 2>&1; then
            error "重打包 vendor_boot.img 失败"
            exit 1
        fi

        # (vendor_tmp removal intentionally skipped for resume.)
    else
        blue "未检测到 vendor_boot.img 仅处理 boot.img"
    fi

    # Clean up the temporary directory.
    cd "${work_dir}" || exit 1
    #rm -rf "${tmp_dir}"
    blue "patch_kernel() 处理完成" "patching done"
}

add_feature() {
    feature=$1
    file=$2
    parent_node=$(xmlstarlet sel -t -m "/*" -v "name()" "$file")
    feature_node=$(xmlstarlet sel -t -m "/*/*" -v "name()" -n "$file" | head -n 1)
    found=0
    while IFS= read -r -d '' xml; do
        if grep -nq "$feature" "$xml" ; then
            blue "功能${feature}已存在，跳过" "Feature $feature already exists, skipping..."
            found=1
        fi
    done < <(find "${work_dir}/build/portrom/images/my_product/etc/" -type f -name "*.xml" -print0)
    if [[ $found == 0 ]] ; then
        blue "添加功能: $feature" "Adding feature $feature"
        sed -i "/<\/$parent_node>/i\\\t\\<$feature_node name=\"$feature\"\/>" "$file"
    fi
}

add_feature_v2() {
    type=$1
    shift # drop the type; the rest are feature entries

    case "$type" in
        oplus_feature)
            dir="${work_dir}/build/portrom/images/my_product/etc/extension"
            base_file="com.oplus.oplus-feature"
            root_tag="oplus-config"
            node_tag="oplus-feature"
            attr_prefix='name='
            ;;
        app_feature)
            dir="${work_dir}/build/portrom/images/my_product/etc/extension"
            base_file="com.oplus.app-features"
            root_tag="extend_features"
            node_tag="app_feature"
            attr_prefix='name=' # args are appended later
            ;;
        permission_feature)
            dir="${work_dir}/build/portrom/images/my_product/etc/permissions"
            base_file="com.oplus.android-features"
            root_tag="permissions"
            node_tag="feature"
            attr_prefix='name='
            ;;
        permission_oplus_feature)
            dir="${work_dir}/build/portrom/images/my_product/etc/permissions"
            base_file="oplus.feature-android"
            root_tag="oplus-config"
            node_tag="oplus-feature"
            attr_prefix='name='
            ;;
        *)
            echo "Invalid feature type: $type"
            return 1
            ;;
    esac

    output_file="$dir/${base_file}-ext-bruce.xml"
    mkdir -p "$dir"

    # Create the file when it does not exist.
    if [[ ! -f "$output_file" ]]; then
        echo "Creating new file: $output_file"
        cat > "$output_file" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<$root_tag>
</$root_tag>
EOF
    fi

    for entry in "$@"; do
    # Split entry into feature, comment, and extra attributes.
    IFS='^' read -r feature comment extra <<< "$entry"

    # Default comment is empty.
    [[ "$feature" == "$comment" ]] && comment=""

    # Default extra is empty.
    [[ -z "$extra" ]] && extra=""

found=0
for xml in $(find ${work_dir}/build/portrom/images/my_product/etc/ -type f -name "*.xml"); do
	if grep -n "$feature" "$xml" | grep -vq "<!--"; then
           blue "功能${feature}已存在，跳过" "Feature $feature already exists, skipping..."
           found=1
           break
    fi
done

    if [[ $found == 0 ]]; then
        blue "✅ 添加 feature: $feature" "✅ feature: $feature Added."

        # Build the attribute string.
        if [[ "$type" == "app_feature" ]]; then
            attrs="name=\"$feature\""
            [[ -n "$extra" ]] && attrs="$attrs $extra"
        else
            attrs="name=\"$feature\""
            [[ -n "$extra" ]] && attrs="$attrs $extra"
        fi

        # Write the comment.
        if [[ -n "$comment" ]]; then
            sed -i "/<\/$root_tag>/i\\\    <!-- $comment -->" "$output_file"
        fi
        # Write the feature node.
        sed -i "/<\/$root_tag>/i\\\    <$node_tag $attrs\/>" "$output_file"
    fi
done
}

remove_feature() {
    feature=$1
    force=$2  # optional second argument, may be "force"

    if [[ "$force" == "force" ]]; then
        blue "强制删除模式开启：忽略原机检测，直接删除 $feature"
    else
        # Non-force mode checks the base ROM first.
        for file in $(find ${work_dir}/build/baserom/images/my_product/etc/ -type f -name "*.xml"); do
            if grep -nq "<!--.*$feature.*-->" "$file"; then
                blue "原机有该feature：$feature，但已被注释，继续删除" "Deleting $feature from $(basename $file) as it is commented out..."
            elif grep -nq "$feature" "$file"; then
                blue "原机有该feature：$feature，跳过删除" "Skip deleting $feature from $(basename $file)..."
                return
            fi
        done
    fi

    # Force or not, delete the feature from the port ROM here.
    for file in $(find ${work_dir}/build/portrom/images/my_product/etc/ -type f -name "*.xml"); do
        if grep -nq "$feature" "$file"; then
            sed -i "/$feature/d" "$file"
            blue "已删除 $feature 于 $(basename $file)"
        fi
    done
}




add_prop_v2(){
    prop=$1
    value=$2
    bruce_prop="${work_dir}/build/portrom/images/my_product/etc/bruce/build.prop"
    portrom_prop="${work_dir}/build/portrom/images/my_product/build.prop"

    # Add to bruce_prop only when neither file has the prop; the key-exists
    # check keeps a resumed run from appending duplicate lines.
    if ! grep -q "^${prop}=" "$bruce_prop" && ! grep -q "^${prop}=" "$portrom_prop"; then
        blue "添加prop: $prop=$value" "Adding prop: $prop=$value"
        echo "$prop=$value" >> "$bruce_prop"
        return
    fi

    # Replace the prop in bruce_prop (when present).
    if grep -q "^${prop}=" "$bruce_prop"; then
        blue "修改prop（bruce）: $prop=$value" "Editing prop (bruce): $prop=$value"
        sed -i "s|^${prop}=.*|${prop}=${value}|" "$bruce_prop"
    fi

    # Replace the prop in portrom_prop (when present).
    if grep -q "^${prop}=" "$portrom_prop"; then
        blue "修改prop（portrom）: $prop=$value" "Editing prop (portrom): $prop=$value"
        sed -i "s|^${prop}=.*|${prop}=${value}|" "$portrom_prop"
    fi
}

remove_prop_v2() {
    prop="${1}"
    force="${2}"
    escaped_prop=$(echo "${prop}" | sed 's/\./\\./g')

    if [[ -n ${force} ]]; then
        blue "强制删除prop: ${prop}" "Force remove prop: ${prop}"
        # Match the full prop name or a prefixed variant (dot, underscore,
        # wildcard suffix). Regex ^ro\.panel\.pad([=_\.].*|$) covers
        # ro.panel.pad= / ro.panel.pad_xxx / ro.panel.pad.xxx.
        sed -i -E "/^(${escaped_prop}([=_\.].*)?$)/s/^/#/" ${work_dir}/build/portrom/images/my_product/etc/bruce/build.prop
        sed -i -E "/^(${escaped_prop}([=_\.].*)?$)/s/^/#/" ${work_dir}/build/portrom/images/my_product/build.prop
    else
        # Check whether the base ROM has the prop (full name or prefix).
        if ! grep -q -E "^(${escaped_prop}([=_\.].*)?$)" ${work_dir}/build/baserom/images/my_product/build.prop; then
            blue "删除prop: ${prop}" "Remove prop: ${prop}"
            sed -i -E "/^(${escaped_prop}([=_\.].*)?$)/s/^/#/" ${work_dir}/build/portrom/images/my_product/etc/bruce/build.prop
        else
            blue "原机存在该prop：${prop}，保留" "Keep prop (exists in base): ${prop}"
        fi
    fi
}
prepare_base_prop() {
    source_build_prop="${work_dir}/build/baserom/images/my_product/build.prop"
    target_build_prop="${work_dir}/build/portrom/images/my_product/build.prop"
    bruce_prop="${work_dir}/build/portrom/images/my_product/etc/bruce/build.prop"

    mkdir -p "$(dirname "$target_build_prop")"
    mkdir -p "$(dirname "$bruce_prop")"

    # Back up the current port ROM build.prop.
    [[ ! -d tmp ]] && mkdir tmp

    cp -f "$target_build_prop" tmp/build.prop.portrom.bak

    # Overwrite the port ROM build.prop with the base ROM's.
    cp -f "$source_build_prop" "$target_build_prop"

    # Reset bruce.build.prop.
    echo "# Properties added by the port" > "$bruce_prop"

    # Add the import line to the new build.prop (avoiding duplicates).
    if ! grep -q "^import /mnt/vendor/my_product/etc/bruce/build.prop" "$target_build_prop"; then
        echo "" >> "$target_build_prop"
        echo "import /mnt/vendor/my_product/etc/bruce/build.prop" >> "$target_build_prop"
    fi
}

add_prop_from_port() {
    base_build_prop="${work_dir}/build/baserom/images/my_product/build.prop"
    old_portrom_prop="${work_dir}/tmp/build.prop.portrom.bak"
    bruce_prop="${work_dir}/build/portrom/images/my_product/etc/bruce/build.prop"

    # Properties that are always forced through.
    force_keys=(
        ro.build.version.oplusrom
        ro.build.version.oplusrom.display
        ro.build.version.oplusrom.confidential
        ro.build.version.realmeui
    )

    # Work through a temporary file.
    temp_file=$(mktemp)

    # Handle ordinary props.
    while IFS='=' read -r key value; do
        [[ -z "$key" || "$key" =~ ^# ]] && continue

        # Skip force-added props (handled below).
        if [[ " ${force_keys[*]} " == *" $key "* ]]; then
            continue
        fi

        if ! awk -F'=' -v property="$key" '$1 == property { found = 1; exit } END { exit !found }' "$base_build_prop"; then
            echo "$key=$value" >> "$temp_file"
            blue "新增: $key=$value" "Added: $key=$value"
        fi
    done < "$old_portrom_prop"

    # Handle force-added props.
    for key in "${force_keys[@]}"; do
        # Read the value safely (strip newlines).
        value=$(grep -m1 "^${key}=" "$old_portrom_prop" | awk -F'=' '{print $2}' | tr -d '\n\r')

        if [[ -n "$value" ]]; then
            # Remove any pre-existing value.
            sed -i "/^${key}=/d" "$temp_file" 2>/dev/null
            echo "$key=$value" >> "$temp_file"
            blue "强制更新属性: $key=$value" "Force update: $key=$value"
        fi
    done

    # Append to the final file.
    cat "$temp_file" >> "$bruce_prop"
    rm -f "$temp_file"
}

smali_wrapper() {
    source_dr=$(realpath $1)
    source_apk=$(realpath $2)
    if [[ $is_eu_rom == "true" ]]; then
       SMALI_COMMAND="java -jar bin/apktool/smali-3.0.5.jar"
       BAKSMALI_COMMAND="java -jar bin/apktool/baksmali-3.0.5.jar"
    else
       SMALI_COMMAND="java -jar bin/apktool/smali.jar"
       BAKSMALI_COMMAND="java -jar bin/apktool/baksmali.jar"
    fi

    for classes_folder in $(find $source_dr -maxdepth 1 -type d -name "classes*");do
        classes=$(basename $classes_folder)
        ${SMALI_COMMAND} a --api ${port_android_sdk} $source_dr/${classes} -o $source_dr/${classes}.dex || error " Smaling 失败" "Smaling failed"
    done

    pushd $source_dr >/dev/null || exit
    for classes_dex in $(find . -type f -name "*.dex"); do
        7z a -y -mx0 -tzip $(realpath $source_apk) $classes_dex >/dev/null || error "修改$source_apk" "Failed to modify $source_apk"
    done
    popd >/dev/null || exit


    yellow "修补$source_apk 完成" "Fix $source_apk completed"
}

baksmali_wrapper() {
    if [[ $is_eu_rom == "true" ]]; then
       SMALI_COMMAND="java -jar bin/apktool/smali-3.0.5.jar"
       BAKSMALI_COMMAND="java -jar bin/apktool/baksmali-3.0.5.jar"
    else
       SMALI_COMMAND="java -jar bin/apktool/smali.jar"
       BAKSMALI_COMMAND="java -jar bin/apktool/baksmali.jar"
    fi
    targetfilefullpath=$1
    if [ -f $targetfilefullpath ];then
        targetfilename=$(basename $targetfilefullpath)
        yellow "正在修改 $targetfilename" "Modifying $targetfilename"
        foldername=${targetfilename%.*}
        rm -rf tmp/$foldername/
        mkdir -p tmp/$foldername/
        cp -rf $targetfilefullpath tmp/$foldername/
        cp tmp/$foldername/$foldername.apk tmp/$foldername/${foldername}_org.apk
        7z x -y tmp/$foldername/$targetfilename *.dex -otmp/$foldername >/dev/null
        for dexfile in tmp/$foldername/*.dex;do
            smalifname=${dexfile%.*}
            smalifname=$(echo $smalifname | cut -d "/" -f 3)
            ${BAKSMALI_COMMAND} d --api ${port_android_sdk} ${dexfile} -o tmp/$foldername/$smalifname 2>&1 || error " Baksmaling 失败" "Baksmaling failed"
        done
    fi
}




convert_version_to_number() {
    local version="$1"
    # Split the version on dots.
    IFS='.' read -ra parts <<< "$version"

    # Pad to at least three parts.
    local major=${parts[0]:-0}
    local minor=${parts[1]:-0}
    local patch=${parts[2]:-0}

    # Numeric form: major*10000 + minor*100 + patch.
    echo $((major * 10000 + minor * 100 + patch))
}

# Read ro.build.version.oplusrom and return the numeric version (V16.1.0 -> 16.1.0).
get_oplusrom_raw_version() {
    local prop_file="${work_dir}/build/portrom/images/my_manifest/build.prop"
    local value
    local candidate
    local best=""
    local best_number=0

    # Newer images expose the plain key; older ColorOS releases only expose
    # the display key (sometimes in more than one partition).  Prefer the
    # plain key, then retain the highest display version for legacy images.
    value=$(grep -E "^ro\.build\.version\.oplusrom=" "${prop_file}" 2>/dev/null | cut -d'=' -f2)
    value=$(printf '%s' "${value}" | sed 's/[^0-9.]//g')
    if [[ -n "${value}" ]]; then
        printf '%s\n' "${value}"
        return 0
    fi

    for prop_file in \
        "${work_dir}/build/portrom/images/my_manifest/build.prop" \
        "${work_dir}/build/portrom/images/my_product/build.prop"; do
        [[ -f "${prop_file}" ]] || continue
        while IFS= read -r candidate; do
            candidate=$(printf '%s' "${candidate}" | sed 's/[^0-9.]//g')
            [[ -n "${candidate}" ]] || continue
            candidate_number=$(convert_version_to_number "${candidate}")
            if (( candidate_number > best_number )); then
                best_number=${candidate_number}
                best=${candidate}
            fi
        done < <(grep -E '^ro\.build\.version\.oplusrom\.display=' "${prop_file}" 2>/dev/null | cut -d'=' -f2)
    done
    printf '%s\n' "${best}"
}

# Compatibility alias retained for the original monolithic port.sh.  Newer
# callers use get_oplusrom_raw_version(), while the online script historically
# called get_oplusrom_version().
get_oplusrom_version() {
    get_oplusrom_raw_version
}

# Small compatibility helpers retained for device-specific overrides from the
# original monolithic script.  Keep the historical API while routing kernel
# surgery through the safer implementation above.
is_property_exists() {
    local property="${1:-}"
    local file="${2:-}"
    [[ -n "${property}" && -f "${file}" ]] || return 1
    grep -Fq -- "${property}" "${file}"
}

patch_kernel_to_bootimg() {
    patch_kernel "$@"
}

# Content-addressed ROM extraction helpers.  The monolithic port script keeps
# its historical build/<version>/ layout, while these helpers add a source
# digest sidecar so a different archive with the same version name can never be
# mistaken for a valid cache hit.
port_sha256_file() {
    local file="${1:-}"
    local output=""
    [[ -f "${file}" ]] || return 1
    if command -v sha256sum >/dev/null 2>&1; then
        output=$(sha256sum -- "${file}") || return 1
    elif command -v shasum >/dev/null 2>&1; then
        output=$(shasum -a 256 "${file}") || return 1
    else
        return 1
    fi
    printf '%s\n' "${output%% *}"
}

port_file_size_bytes() {
    local file="${1:-}"
    [[ -f "${file}" ]] || return 1
    if [[ "${OSTYPE:-}" == darwin* ]]; then
        stat -f%z "${file}"
    else
        stat -c%s "${file}"
    fi
}

port_tree_size_bytes() {
    local root="${1:-}"
    local file size total=0
    [[ -d "${root}" ]] || return 1
    while IFS= read -r -d '' file; do
        size="$(port_file_size_bytes "${file}")" || return 1
        total=$((total + size))
    done < <(find "${root}" -type f -print0)
    printf '%s\n' "${total}"
}

port_rom_fingerprint() {
    local rom="${1:-}"
    port_sha256_file "${rom}"
}

port_cache_dir() {
    local role="${1:-rom}"
    local hash="${2:-}"
    [[ "${hash}" =~ ^[[:xdigit:]]{16,64}$ ]] || return 1
    printf '%s/build/cache/roms/%s_%s\n' "${work_dir:-$(pwd)}" "${hash:0:16}" "${role}"
}

port_cache_has_images() {
    local dir="${1:-}"
    local partition_list="${2:-}"
    local part
    local -a parts=()
    [[ -d "${dir}" ]] || return 1
    IFS=',' read -r -a parts <<< "${partition_list}"
    for part in "${parts[@]}"; do
        [[ -z "${part}" ]] && continue
        [[ -s "${dir}/${part}.img" ]] || return 1
    done
}

port_cache_store_images() {
    local dir="${1:-}"
    local source_dir="${2:-}"
    local hash="${3:-}"
    local role="${4:-rom}"
    local version="${5:-}"
    local image
    local image_count=0
    [[ -d "${source_dir}" && -n "${hash}" ]] || return 1
    mkdir -p "${dir}" || return 1
    for image in "${source_dir}"/*.img; do
        [[ -s "${image}" ]] || continue
        cp -f -- "${image}" "${dir}/" || return 1
        image_count=$((image_count + 1))
    done
    # Do not publish an apparently valid sidecar for an empty extraction.  A
    # zero-image entry would make a later run treat the cache directory as
    # authoritative even though no partition can be restored from it.
    (( image_count > 0 )) || return 1
    printf 'role=%s\nhash=%s\nversion_name=%s\nsource=%s\ntimestamp=%s\n' \
        "${role}" "${hash}" "${version}" "${source_dir}" \
        "$(date +%Y-%m-%dT%H:%M:%S%z)" > "${dir}/${hash}.info"
}

# Safely clear only a cache entry that belongs to the project root.
port_cache_clear() {
    local dir="${1:-}"
    local root="${work_dir:-$(pwd)}/build/cache/roms"
    [[ -n "${dir}" && "${dir}" == "${root}"/* ]] || return 1
    rm -rf -- "${dir}"
}

# Transactional image packers shared by the monolithic entry point.  Build into
# a temporary file and publish only after the tool succeeds and the output is
# non-empty, so a failed rerun cannot leave a stale image that looks valid.
_port::pack_partition_erofs() {
    local pname="$1"
    local src_dir="$2"
    local fs_cfg="$3"
    local file_ctx="$4"
    local out_img="$5"
    local tmp_img="${out_img}.tmp.$$"
    rm -f -- "${tmp_img}"
    if ! mkfs.erofs -zlz4hc,12 --mount-point "${pname}" \
        --fs-config-file "${fs_cfg}" \
        --file-contexts "${file_ctx}" \
        -T 1648635685 "${tmp_img}" "${src_dir}"; then
        rm -f -- "${tmp_img}"
        return 1
    fi
    [[ -s "${tmp_img}" ]] || { rm -f -- "${tmp_img}"; return 1; }
    mv -f -- "${tmp_img}" "${out_img}"
}

_port::pack_partition_ext4() {
    local pname="$1"
    local src_dir="$2"
    local fs_cfg="$3"
    local file_ctx="$4"
    local out_img="$5"
    local raw_size="${6:-0}"
    local tmp_img="${out_img}.tmp.$$"
    local margin=$(( raw_size * 15 / 100 ))
    (( margin < 33554432 )) && margin=33554432
    local total_size=$(( raw_size + margin ))
    total_size=$(( ((total_size + 4095) / 4096) * 4096 ))
    rm -f -- "${tmp_img}"
    if ! make_ext4fs -J -T 1648635685 \
        -S "${file_ctx}" -l "${total_size}" -C "${fs_cfg}" \
        -L "${pname}" -a "${pname}" "${tmp_img}" "${src_dir}"; then
        rm -f -- "${tmp_img}"
        return 1
    fi
    [[ -s "${tmp_img}" ]] || { rm -f -- "${tmp_img}"; return 1; }
    mv -f -- "${tmp_img}" "${out_img}"
}

# Legacy property helpers used by older device overrides.  Keep them beside
# the optimized add_prop_v2/remove_prop_v2 implementations so existing
# devices continue to work after the helper library is upgraded.
update_prop_from_base() {
    local source_build_prop="${work_dir}/build/baserom/images/my_product/build.prop"
    local target_build_prop="${work_dir}/build/portrom/images/my_product/build.prop"
    [[ -f "${source_build_prop}" && -f "${target_build_prop}" ]] || return 1
    mkdir -p "${work_dir}/tmp"
    cp -f -- "${target_build_prop}" "${work_dir}/tmp/$(basename "${target_build_prop}").port"
    while IFS= read -r line; do
        [[ -z "${line}" || "${line}" == \#* || "${line}" == *oplusrom* || "${line}" == *date* ]] && continue
        local key="${line%%=*}"
        local value="${line#*=}"
        [[ -n "${key}" ]] || continue
        if grep -q "^${key}=" "${target_build_prop}"; then
            sed -i "s|^${key}=.*|${key}=${value}|" "${target_build_prop}"
        else
            printf '%s=%s\n' "${key}" "${value}" >> "${target_build_prop}"
        fi
    done < "${source_build_prop}"
}

add_prop() {
    local prop="${1:-}"
    local value="${2:-}"
    local target="${work_dir}/build/portrom/images/my_product/build.prop"
    [[ -n "${prop}" && -f "${target}" ]] || return 1
    if grep -q "^${prop}=" "${target}"; then
        sed -i "s|^${prop}=.*|${prop}=${value}|" "${target}"
    else
        printf '%s=%s\n' "${prop}" "${value}" >> "${target}"
    fi
}

remove_prop() {
    local prop="${1:-}"
    local target="${work_dir}/build/portrom/images/my_product/build.prop"
    local base="${work_dir}/build/baserom/images/my_product/build.prop"
    [[ -n "${prop}" && -f "${target}" ]] || return 1
    if [[ ! -f "${base}" ]] || ! grep -q "^${prop}=" "${base}"; then
        sed -i "/^${prop}=/d" "${target}"
    fi
}

# AnyKernel helpers used by the legacy monolithic entry point.  Keep the
# classifier strict about NoKSU before KSU because both tokens overlap, and
# normalize common ReSukiSU spellings used by device archives.
_port::anykernel_variant_for_zip() {
    local zip_name="${1##*/}"
    local normalized
    normalized="$(_port::lower "${zip_name}")"
    local compact="${normalized//[-_]/}"
    if [[ "${compact}" == *noksu* || "${compact}" == *nokisu* ]]; then
        printf '%s\n' noksu
    elif [[ "${compact}" == *ksu* || "${compact}" == *sukisu* || "${compact}" == *resukisu* ]]; then
        printf '%s\n' ksu
    else
        printf '%s\n' custom
    fi
}

_port::clear_anykernel_outputs() {
    local device_dir="${1:-}"
    [[ -n "${device_dir}" ]] || return 1
    rm -f -- \
        "${device_dir}/boot_ksu.img" \
        "${device_dir}/boot_noksu.img" \
        "${device_dir}/boot_custom.img" \
        "${device_dir}/dtbo_ksu.img" \
        "${device_dir}/dtbo_noksu.img" \
        "${device_dir}/dtbo_custom.img"
}

# Version comparison: ver_gte <current> <target>.
# Returns 0 (true) when current >= target, otherwise 1 (false).
# Usage: if ver_gte $port_oplusrom_version 16.1.0; then ...
ver_gte() {
    local current_num
    local target_num
    current_num=$(convert_version_to_number "$1")
    target_num=$(convert_version_to_number "$2")
    [[ $current_num -ge $target_num ]]
}


trap 'error "强制中断脚本运行，以免误删重要文件！" "Script interrupted! Exiting to prevent accidental deletion." ; exit 1' SIGINT


certificatechainPatch() {
 certificatechainPatch="
    # OplusIdentityFramework rewrites the returned leaf certificate below.
"
}

ApplicationPackageManagerPatch() {
    # The register holding the primitive result is not stable across Android
    # releases.  Android 15's hasSystemFeature() keeps the query object in v1
    # and returns the Boolean result through v0, while newer framework builds
    # commonly return through v1.  Reusing the query-object register as a Z
    # argument makes ART reject the method with VerifyError.
    local result_reg="${1:-v1}"
    ApplicationPackageManagerPatch="
        invoke-static {p1, ${result_reg}}, Lcom/android/internal/util/PropsHookUtils;->hasSystemFeature(Ljava/lang/String;Z)Z

        move-result ${result_reg}
    "
}

instrumentationPatch() {
	returnline=$(( $2 + 1 ))
	instrumentationPatch="    invoke-static {$1}, Lcom/android/internal/util/PropsHookUtils;->setProps(Landroid/content/Context;)V

    invoke-static {$1}, Lcom/android/internal/security/oplusidentity/OplusIdentityFramework;->onNewApplication(Landroid/content/Context;)V

    "

}

blSpoofPatch() {
	blSpoofPatch="    invoke-static {$1}, Lcom/android/internal/security/oplusidentity/OplusIdentityFramework;->spoofCertificateChain([Ljava/security/cert/Certificate;)[Ljava/security/cert/Certificate;

    move-result-object $1
    "
}

expressions_fix() {
	var=$1
	escaped_var=$(printf '%s\n' "$var" | sed 's/[\/&]/\\&/g')
	escaped_var=$(printf '%s\n' "$escaped_var" | sed 's/\[/\\[/g' | sed 's/\]/\\]/g' | sed 's/\./\\./g' | sed 's/;/\\;/g')
	echo $escaped_var
}

# Get the image size, handling the sparse format (avoids duplicated code).
function get_image_size() {
    local img_path="$1"

    # 1. Convert the sparse image to raw first.
    # Invariant: the sparse image must be converted before measuring, otherwise
    # the size is taken from the sparse header and the build fails with
    # "Image for partition ... is greater than its size".
    mv "$img_path" "${img_path}.bak"
    if ! simg2img "${img_path}.bak" "$img_path" 2>/dev/null; then
        # Conversion failure usually means it is already raw; restore it.
        mv "${img_path}.bak" "$img_path"
    else
        # Conversion succeeded; drop the backup.
        rm "${img_path}.bak"
    fi

    # 2. Compute the file size (macOS and Linux compatible).
    local raw_size
    raw_size="$(port_file_size_bytes "$img_path")" || return 1

    # 3. Add a 4KB safety buffer to prevent alignment overflow.
    echo $(($raw_size + 4096))
}

# =========================================================
# KernelSU (KSU) Integration Functions
# Ported from Python firmware_modifier.py
# =========================================================

# Check if KMI version supports KernelSU (GKI 2.0+)
# KSU requires Android 12+ (KMI format: android12-5.10 or higher)
# Usage: is_kmi_ksu_supported <kmi_version>
# Returns: 0 if supported, 1 if not
is_kmi_ksu_supported() {
    local kmi_version="$1"

    if [[ -z "$kmi_version" ]]; then
        return 1
    fi

    # Extract Android version number from KMI (e.g., "android14-5.15" -> 14)
    local android_ver
    android_ver=$(echo "$kmi_version" | grep -oE 'android[0-9]+' | grep -oE '[0-9]+')

    if [[ -z "$android_ver" ]]; then
        return 1
    fi

    # KSU requires Android 12+ (GKI 2.0)
    if [[ "$android_ver" -ge 12 ]]; then
        return 0
    else
        return 1
    fi
}

# Analyze kernel image to extract KMI version
# Usage: analyze_kmi_from_boot <boot_img_path>
# Returns: KMI string (e.g., "android14-5.15") or empty string on failure
analyze_kmi_from_boot() {
    local boot_img="$1"
    local tmp_dir=""
    PORT_KMI_RESULT=""

    if [[ ! -f "$boot_img" ]]; then
        yellow "boot.img 不存在，跳过 KMI 分析" "boot.img not found, skipping KMI analysis"
        return 1
    fi

    if ! tmp_dir=$(mktemp -d -p "${work_dir}/tmp" ksu_kmi_XXXXXX); then
        yellow "无法创建 KMI 临时目录" "Could not create KMI temporary directory"
        return 1
    fi

    blue "分析 KMI 版本..." "Analyzing KMI version..."

    if ! cp "$boot_img" "${tmp_dir}/boot.img"; then
        rm -rf -- "$tmp_dir"
        return 1
    fi

    # Unpack boot image using magiskboot
    if ! (cd "${tmp_dir}" && magiskboot unpack boot.img > /dev/null 2>&1); then
        yellow "magiskboot 解包失败" "magiskboot unpack failed"
        rm -rf -- "$tmp_dir"
        return 1
    fi

    # Check if kernel file exists
    if [[ ! -f "${tmp_dir}/kernel" ]]; then
        yellow "未找到 kernel 文件" "Kernel file not found after unpack"
        rm -rf -- "$tmp_dir"
        return 1
    fi

    # Extract printable strings and search for KMI pattern
    # Pattern: version number followed by android version (e.g., "5.15.android14")
    local kmi_version=""

    # Use strings command to extract printable strings, then grep for pattern
    # Look for lines containing "Linux version" or "android"
    while IFS= read -r line; do
        if [[ "$line" == *"Linux version"* ]] || [[ "$line" == *"android"* ]]; then
            # Extract pattern like "5.15.android14" or "6.1.android15"
            local match
            match=$(echo "$line" | grep -oE '[0-9]+\.[0-9]+[^[:space:]]*android[0-9]+' | head -n1)
            if [[ -n "$match" ]]; then
                # Extract version components
                local kernel_ver android_ver
                kernel_ver=$(echo "$match" | grep -oE '^[0-9]+\.[0-9]+')
                android_ver=$(echo "$match" | grep -oE 'android[0-9]+')
                if [[ -n "$kernel_ver" && -n "$android_ver" ]]; then
                    kmi_version="${android_ver}-${kernel_ver}"
                    break
                fi
            fi
        fi
    done < <(strings "${tmp_dir}/kernel" 2>/dev/null)

    # Fallback: try alternative patterns if first method failed
    if [[ -z "$kmi_version" ]]; then
        local kernel_strings
        kernel_strings=$(strings "${tmp_dir}/kernel" 2>/dev/null | grep -E '[0-9]+\.[0-9]+.*android[0-9]+' | head -n1)
        if [[ -n "$kernel_strings" ]]; then
            local kernel_part android_part
            kernel_part=$(echo "$kernel_strings" | grep -oE '[0-9]+\.[0-9]+' | head -n1)
            android_part=$(echo "$kernel_strings" | grep -oE 'android[0-9]+' | head -n1)
            if [[ -n "$kernel_part" && -n "$android_part" ]]; then
                kmi_version="${android_part}-${kernel_part}"
            fi
        fi
    fi

    rm -rf -- "$tmp_dir"

    if [[ -n "$kmi_version" ]]; then
        PORT_KMI_RESULT="$kmi_version"
        green "检测到 KMI 版本: $kmi_version" "Detected KMI version: $kmi_version"
        return 0
    else
        yellow "无法从 kernel 中提取 KMI 版本" "Could not extract KMI version from kernel"
        return 1
    fi
}

# Download KernelSU assets from GitHub release
# Usage: prepare_ksu_assets <kmi_version>
# Returns: 0 on success, 1 on failure
prepare_ksu_assets() {
    local kmi_version="$1"
    local assets_dir="${work_dir}/assets"
    local ksu_repo_owner="${ksu_repo_owner:-tiann}"
    local ksu_repo_name="${ksu_repo_name:-KernelSU}"

    if [[ -z "$kmi_version" ]]; then
        error "KMI 版本为空，无法准备 KSU 资源" "KMI version is empty, cannot prepare KSU assets"
        return 1
    fi

    # Check if KMI supports KSU (Android 12+ / GKI 2.0+)
    if ! is_kmi_ksu_supported "$kmi_version"; then
        yellow "KMI $kmi_version 不支持 KernelSU（需要 Android 12+ GKI 2.0）" "KMI $kmi_version does not support KernelSU (requires Android 12+ GKI 2.0)"
        return 1
    fi

    mkdir -p "$assets_dir"

    local ko_filename="${kmi_version}_kernelsu.ko"
    local init_filename="ksuinit"
    local target_ko="${assets_dir}/${ko_filename}"
    local target_init="${assets_dir}/${init_filename}"

    # Check if assets already exist
    if [[ -f "$target_ko" && -f "$target_init" ]]; then
        green "KSU 资源已存在，跳过下载" "KSU assets already exist, skipping download"
        return 0
    fi

    blue "下载 KernelSU 资源..." "Downloading KernelSU assets..."

    local api_url="https://api.github.com/repos/${ksu_repo_owner}/${ksu_repo_name}/releases/latest"
    local temp_json
    temp_json=$(mktemp -p "${work_dir}/tmp")

    # Download release info
    if ! curl -sL --connect-timeout 15 --max-time 60 "$api_url" -o "$temp_json" 2>/dev/null; then
        error "下载 KSU 发布信息失败" "Failed to download KSU release info"
        rm -f "$temp_json"
        return 1
    fi

    # Parse assets using grep/sed (avoiding jq dependency if possible)
    local download_success=false

    # Download ksuinit if needed
    if [[ ! -f "$target_init" ]]; then
        local init_url
        init_url=$(grep -o '"browser_download_url": "[^"]*ksuinit"' "$temp_json" | sed 's/.*"browser_download_url": "\([^"]*\)".*/\1/' | head -n1)
        if [[ -n "$init_url" ]]; then
            blue "下载 ksuinit..." "Downloading ksuinit..."
            if curl -sL --connect-timeout 30 --max-time 120 "$init_url" -o "$target_init" 2>/dev/null; then
                chmod 755 "$target_init"
                green "ksuinit 下载成功" "ksuinit downloaded successfully"
            else
                yellow "ksuinit 下载失败" "Failed to download ksuinit"
            fi
        else
            yellow "未找到 ksuinit 下载链接" "ksuinit download URL not found"
        fi
    fi

    # Download kernel module if needed
    if [[ ! -f "$target_ko" ]]; then
        local ko_url
        ko_url=$(grep -o '"browser_download_url": "[^"]*'"${ko_filename}"'"' "$temp_json" | sed 's/.*"browser_download_url": "\([^"]*\)".*/\1/' | head -n1)
        if [[ -n "$ko_url" ]]; then
            blue "下载 ${ko_filename}..." "Downloading ${ko_filename}..."
            if curl -sL --connect-timeout 30 --max-time 120 "$ko_url" -o "$target_ko" 2>/dev/null; then
                green "${ko_filename} 下载成功" "${ko_filename} downloaded successfully"
            else
                yellow "${ko_filename} 下载失败" "Failed to download ${ko_filename}"
            fi
        else
            yellow "未找到 ${ko_filename} 下载链接" "${ko_filename} download URL not found"
        fi
    fi

    rm -f "$temp_json"

    # Verify both files exist
    if [[ -f "$target_ko" && -f "$target_init" ]]; then
        green "KSU 资源准备完成" "KSU assets prepared successfully"
        return 0
    else
        error "KSU 资源准备失败" "Failed to prepare KSU assets"
        return 1
    fi
}

# Apply KernelSU patch to boot/init_boot image
# Usage: apply_ksu_patch <target_img_path> <kmi_version>
apply_ksu_patch() {
    local target_img="$1"
    local kmi_version="$2"
    local tmp_dir
    tmp_dir=$(mktemp -d -p "${work_dir}/tmp" ksu_patch_XXXXXX)

    if [[ ! -f "$target_img" ]]; then
        error "目标镜像不存在: $target_img" "Target image not found: $target_img"
        rm -rf "$tmp_dir"
        return 1
    fi

    if [[ -z "$kmi_version" ]]; then
        error "KMI 版本为空" "KMI version is empty"
        rm -rf "$tmp_dir"
        return 1
    fi

    local assets_dir="${work_dir}/assets"
    local ko_filename="${kmi_version}_kernelsu.ko"
    local init_filename="ksuinit"
    local ko_file="${assets_dir}/${ko_filename}"
    local init_file="${assets_dir}/${init_filename}"

    if [[ ! -f "$ko_file" || ! -f "$init_file" ]]; then
        error "KSU 资源文件缺失" "KSU asset files missing"
        rm -rf "$tmp_dir"
        return 1
    fi

    local img_name
    img_name=$(basename "$target_img")
    blue "正在为 ${img_name} 应用 KernelSU 补丁..." "Applying KernelSU patch to ${img_name}..."

    # Copy target image to temp directory
    cp "$target_img" "${tmp_dir}/boot.img"
    cd "$tmp_dir" || { rm -rf "$tmp_dir"; return 1; }

    # Step 1: Unpack boot image
    if ! magiskboot unpack boot.img > /dev/null 2>&1; then
        error "magiskboot 解包失败" "magiskboot unpack failed"
        cd "$work_dir" || true
        rm -rf "$tmp_dir"
        return 1
    fi

    # Step 2: Check if ramdisk.cpio exists
    if [[ ! -f "ramdisk.cpio" ]]; then
        error "未找到 ramdisk.cpio" "ramdisk.cpio not found"
        cd "$work_dir" || true
        rm -rf "$tmp_dir"
        return 1
    fi

    # Step 3: Move init to init.real
    if ! magiskboot cpio ramdisk.cpio "mv init init.real" > /dev/null 2>&1; then
        yellow "移动 init 失败，可能不存在" "Moving init failed, may not exist"
    fi

    # Step 4: Copy ksuinit as init and add to ramdisk
    cp "$init_file" "${tmp_dir}/init"
    if ! magiskboot cpio ramdisk.cpio "add 0755 init init" > /dev/null 2>&1; then
        error "添加 init 到 ramdisk 失败" "Failed to add init to ramdisk"
        cd "$work_dir" || true
        rm -rf "$tmp_dir"
        return 1
    fi

    # Step 5: Copy kernel module and add to ramdisk
    cp "$ko_file" "${tmp_dir}/kernelsu.ko"
    if ! magiskboot cpio ramdisk.cpio "add 0755 kernelsu.ko kernelsu.ko" > /dev/null 2>&1; then
        error "添加 kernelsu.ko 到 ramdisk 失败" "Failed to add kernelsu.ko to ramdisk"
        cd "$work_dir" || true
        rm -rf "$tmp_dir"
        return 1
    fi

    # Step 6: Repack boot image
    if ! magiskboot repack boot.img > /dev/null 2>&1; then
        error "magiskboot 重打包失败" "magiskboot repack failed"
        cd "$work_dir" || true
        rm -rf "$tmp_dir"
        return 1
    fi

    # Step 7: Move new image to target location
    if [[ -f "${tmp_dir}/new-boot.img" ]]; then
        mv -f "${tmp_dir}/new-boot.img" "$target_img"
        green "KernelSU 注入成功: ${img_name}" "KernelSU injected successfully: ${img_name}"
    else
        error "重打包后的镜像不存在" "Repacked image not found"
        cd "$work_dir" || true
        rm -rf "$tmp_dir"
        return 1
    fi

    cd "$work_dir" || true
    rm -rf "$tmp_dir"
    return 0
}

# Patch vbmeta.img to disable AVB verification
# Usage: patch_vbmeta <vbmeta_img_path>
patch_vbmeta() {
    local vbmeta_img="$1"
    local AVB_MAGIC="AVB0"
    local FLAGS_OFFSET=123
    local FLAGS_TO_SET=$'\x01'

    if [[ ! -f "$vbmeta_img" ]]; then
        yellow "vbmeta.img 不存在，跳过修补" "vbmeta.img not found, skipping patch"
        return 0
    fi

    blue "修补 vbmeta.img (禁用 AVB)..." "Patching vbmeta.img (Disabling AVB)..."

    # Check AVB magic header
    local magic
    magic=$(xxd -l 4 -p "$vbmeta_img" 2>/dev/null || od -A n -N 4 -t x1 "$vbmeta_img" 2>/dev/null | tr -d ' \n')

    if [[ "$magic" != "41564230" ]]; then  # 41564230 = "AVB0" in hex
        yellow "无效的 AVB 魔法头，跳过: $vbmeta_img" "Invalid AVB magic header, skipping: $vbmeta_img"
        return 0
    fi

    # Patch at offset 123 to set flag 0x01 (Android 16 base builds compatibility)
    if printf '\x01' | dd of="$vbmeta_img" bs=1 seek=123 count=1 conv=notrunc 2>/dev/null; then
        green "vbmeta.img 修补成功" "vbmeta.img patched successfully"
        return 0
    else
        yellow "vbmeta.img 修补失败" "Failed to patch vbmeta.img"
        return 1
    fi
}

# ============================================================
# GitHub Release asset downloads (kept in sync with the online COS16 branch).
# ============================================================

export REPO_OWNER="${REPO_OWNER:-toraidl}"
export REPO_NAME="${REPO_NAME:-coloros_port}"
export RELEASE_TAG="${RELEASE_TAG:-assets}"

# Check if GitHub CLI is installed
check_gh_cli() {
    if ! command -v gh > /dev/null 2>&1; then
        yellow "未找到 GitHub CLI (gh)。" "GitHub CLI (gh) not found."
        return 1
    fi
    return 0
}

# Generate asset name for GitHub Release (based on tools/upload_assets.sh logic)
generate_asset_name() {
    local file_path="$1"
    local dir_path
    dir_path=$(dirname "$file_path")
    local filename
    filename=$(basename "$file_path")
    local asset_name=""

    if [[ "$dir_path" == *"devices/"* ]]; then
        # Extract first level directory name under devices/ as prefix
        local prefix
        prefix=$(echo "$dir_path" | sed 's/.*devices\///' | cut -d'/' -f1)
        asset_name="${prefix}_${filename}"
    elif [[ "$dir_path" == *"assets"* ]]; then
        asset_name="assets_${filename}"
    else
        asset_name="$filename"
    fi

    echo "$asset_name"
}

# Download specified asset from GitHub Release
download_from_release() {
    local file_path="$1"

    if [[ ! -f "$file_path" ]]; then
        local asset_name
        asset_name=$(generate_asset_name "$file_path")
        local download_url="https://github.com/${REPO_OWNER}/${REPO_NAME}/releases/download/${RELEASE_TAG}/${asset_name}"

        blue "尝试从 GitHub Release 下载: $file_path" "Attempting download from GitHub Release: $file_path"
        blue "     GitHub Asset Name: $asset_name" "GitHub Asset Name: $asset_name"
        blue "     Download URL: $download_url" "Download URL: $download_url"

        mkdir -p "$(dirname "$file_path")"

        # Try using GitHub CLI first
        if check_gh_cli; then
            if gh release download "$RELEASE_TAG" --repo "$REPO_OWNER/$REPO_NAME" --pattern "$asset_name" --dir "$(dirname "$file_path")" 2>/dev/null; then
                local downloaded_file
                downloaded_file=$(find "$(dirname "$file_path")" -name "$asset_name" -type f 2>/dev/null | head -n1)
                if [[ -n "$downloaded_file" && "$downloaded_file" != "$file_path" ]]; then
                    mv "$downloaded_file" "$file_path"
                fi
                if [[ -f "$file_path" ]]; then
                    blue "通过 GitHub CLI 成功下载: $file_path" "Successfully downloaded via GitHub CLI: $file_path"
                    return 0
                fi
            fi
            yellow "GitHub CLI 下载失败，尝试直接下载..." "GitHub CLI download failed, trying direct download..."
        fi

        # If GitHub CLI unavailable or fails, use curl for direct download
        if curl -L --fail -o "$file_path.tmp" "$download_url"; then
            mv "$file_path.tmp" "$file_path"
            blue "直接下载成功: $file_path" "Direct download successful: $file_path"
            return 0
        else
            rm -f "$file_path.tmp"
            error "下载失败: $file_path (URL: $download_url)" "Download failed: $file_path (URL: $download_url)"
            return 1
        fi
    else
        green "文件已存在，跳过下载: $file_path" "File already exists, skipping download: $file_path"
    fi
}

# Quick check function to download file if it's missing from GitHub Release (only when not exists locally)
ensure_resource_available() {
    local resource_path="$1"

    if [[ ! -f "$resource_path" ]]; then
        yellow "本地缺失资源: $resource_path，正在尝试下载..." "Resource missing locally: $resource_path, attempting download..."
        if download_from_release "$resource_path"; then
            return 0
        else
            error "错误: 无法获取所需资源 $resource_path" "Error: Could not acquire required resource $resource_path"
            error "请手动放置文件或上传到 GitHub Release" "Please place file manually or upload to GitHub Release"
            return 1
        fi
    else
        green "资源已存在: $resource_path" "Resource exists: $resource_path"
        return 0
    fi
}

# Insert the optional Oplus identity manager entry into the decoded Settings
# preference XML.  The helper is deliberately self-contained so the online
# repository keeps its historical single-script layout; when the target XML or
# marker preference is absent it is a no-op rather than a build blocker.
patch_oplus_identity_settings_entry() {
    local settings_xml="${1:-}"
    [[ -f "${settings_xml}" ]] || return 0
    grep -q 'android:key="oplus_identity_manager"' "${settings_xml}" && return 0
    grep -q 'android:key="oplus_google_settings"' "${settings_xml}" || return 0

    SETTINGS_XML_PATH="${settings_xml}" python3 - <<'PY'
from pathlib import Path
import os
import re

path = Path(os.environ["SETTINGS_XML_PATH"])
text = path.read_text(encoding="utf-8")
tag = "com.oplus.settings.widget.preference.SettingsSimpleJumpPreference"
pattern = re.compile(
    rf"(<{re.escape(tag)}\b[^>]*\bandroid:key=\"oplus_google_settings\"[^>]*(?:/>|>))",
    re.DOTALL,
)
match = pattern.search(text)
if match is None:
    raise SystemExit("target Oplus Google Settings preference element not found")

insert_at = match.end()
opening = match.group(1)
if not opening.rstrip().endswith("/>"):
    closing = f"</{tag}>"
    closing_at = text.find(closing, match.end())
    if closing_at < 0:
        raise SystemExit("target Oplus Google Settings preference is not closed")
    insert_at = closing_at + len(closing)

newline = "\r\n" if "\r\n" in text else "\n"
insertion = newline.join(
    (
        "        <com.oplus.settings.widget.preference.SettingsSimpleJumpPreference "
        'android:layout="@layout/coui_preference" '
        'android:title="Oplus 身份管理" '
        'android:key="oplus_identity_manager" '
        'android:order="3260" '
        'settings:layoutCategory="no_icon_and_summary">',
        '            <intent android:targetPackage="com.oplus.identitymanager" '
        'android:targetClass="com.oplus.identitymanager.MainActivity" />',
        "        </com.oplus.settings.widget.preference.SettingsSimpleJumpPreference>",
    )
)
path.write_text(text[:insert_at] + newline + insertion + text[insert_at:], encoding="utf-8", newline="")
PY
}

# The two legacy patch entry points are kept as explicit, fail-safe shims.  A
# caller that still requests them gets a clear status and the modern helper
# names remain available for all current device definitions.
fix_oldfaceunlock() {
    yellow "旧版人脸解锁补丁接口已停用，请使用显式 face-unlock 资源" \
        "Legacy face-unlock patch entry point is disabled; use an explicit face-unlock resource"
    return 1
}

patch_smartsidecar() {
    yellow "旧版 SmartSideBar 补丁接口已停用，请使用设备资源" \
        "Legacy SmartSideBar patch entry point is disabled; use a device resource"
    return 1
}

# Optional Oplus identity/PIF resources. The source tree deliberately stays
# outside the public checkout (large generated APK/tool inputs are downloaded
# from the release asset store when available), but these hooks make the
# optimized pipeline consume them when a maintainer supplies them.
install_oplus_identity_pif_assets() {
    local source_root="devices/common/oplus_identity_pif/ROM"
    local image_root="build/portrom/images"
    [[ -d "${source_root}" ]] || return 0

    local source_file relative target
    while IFS= read -r -d '' source_file; do
        relative="${source_file#"${source_root}/"}"
        target="${image_root}/${relative}"
        mkdir -p "$(dirname "${target}")" || return 1
        if [[ -x "${source_file}" ]]; then
            install -m 0755 "${source_file}" "${target}" || return 1
        else
            install -m 0644 "${source_file}" "${target}" || return 1
        fi
    done < <(find "${source_root}" -type f \( -path '*/system/bin/*' -o -path '*/system/etc/init/*' \) -print0)
}

install_property_compat_policy() {
    local source=""
    local candidate
    for candidate in \
        "devices/${base_product_device:-}/property_compat.json" \
        "devices/common/property_compat.json" \
        "resources/property_compat.json"; do
        if [[ -f "${candidate}" ]]; then
            source="${candidate}"
            break
        fi
    done
    [[ -n "${source}" ]] || return 0
    python3 -m json.tool "${source}" >/dev/null 2>&1 || {
        error "property_compat.json 格式无效: ${source}" \
            "Invalid property_compat.json syntax: ${source}"
        return 1
    }
    local destination="build/portrom/images/system_ext/etc/oplus/property_compat.json"
    mkdir -p "$(dirname "${destination}")" || return 1
    install -m 0644 "${source}" "${destination}" || return 1
    blue "已安装属性兼容策略: ${source}" \
        "Installed property compatibility policy: ${source}"
}

ensure_android_ext_shared_library() {
    local image_root="build/portrom/images"
    local target="${image_root}/my_bigball/non_overlay/app/GoogleExtShared/GoogleExtShared.apk"
    local source=""
    local candidate
    [[ -d "${image_root}/my_bigball" ]] || return 0
    if [[ ! -f "${target}" ]]; then
        for candidate in \
            "${image_root}/my_product/non_overlay/app/GoogleExtShared/GoogleExtShared.apk" \
            "build/baserom/images/my_product/non_overlay/app/GoogleExtShared/GoogleExtShared.apk"; do
            if [[ -f "${candidate}" ]]; then
                source="${candidate}"
                break
            fi
        done
        [[ -n "${source}" ]] || return 0
        mkdir -p "$(dirname "${target}")" || return 1
        mv -f -- "${source}" "${target}" || return 1
    fi

    local contexts="${image_root}/config/my_bigball_file_contexts"
    local fs_config="${image_root}/config/my_bigball_fs_config"
    if [[ -f "${contexts}" ]] && ! grep -qF '/my_bigball/non_overlay/app/GoogleExtShared' "${contexts}"; then
        printf '%s\tu:object_r:system_file:s0\n' \
            '/my_bigball/non_overlay/app/GoogleExtShared(/.*)?' >> "${contexts}"
    fi
    if [[ -f "${fs_config}" ]] && ! grep -qF 'my_bigball/non_overlay/app/GoogleExtShared' "${fs_config}"; then
        printf '%s\t0 0 755\n' 'my_bigball/non_overlay/app/GoogleExtShared' >> "${fs_config}"
    fi
}

# Android 17 ports that retain a Qualcomm/Oplus HIDL IMS declaration need the
# VNDK-30-compatible IMS APK.  Select it only for HIDL-only manifests; an AIDL
# declaration or a missing release asset leaves the donor stack untouched.
_port::vintf_ims_hal_matches() {
    local manifest="${1:-}"
    local expected_format="${2:-}"
    [[ -f "${manifest}" ]] || return 1
    awk -v expected_format="${expected_format}" '
        BEGIN { RS="</hal>"; found=0 }
        {
            block=tolower($0)
            format_token="<hal[^>]*format[[:space:]]*=[[:space:]]*\"" expected_format "\""
            if (block ~ format_token &&
                (block ~ /<name>[[:space:]]*vendor\.qti\.hardware\.radio\.ims[[:space:]]*<\/name>/ ||
                 block ~ /<name>[[:space:]]*vendor\.oplus\.hardware\.ims[[:space:]]*<\/name>/ ||
                 block ~ /iimsradio/ || block ~ /ioplusimsradio/)) found=1
        }
        END { exit(found ? 0 : 1) }
    ' "${manifest}"
}

_port::patch_ims_stack_for_vndk30() {
    [[ "${port_android_version:-}" == 17 ]] || return 0
    local image_root="build/portrom/images"
    local ims_patch="${work_dir:-${PWD}}/devices/common/ims-hidl-android17.apk"
    local vintf_root manifest target
    local -a vintf_roots=(
        "${image_root}/vendor/etc/vintf"
        "${image_root}/odm/etc/vintf"
    )
    local -a hidl_manifests=()
    local -a aidl_manifests=()
    local -a stale_oat=(
        "priv-app/ims/oat/arm64/ims.odex"
        "priv-app/ims/oat/arm64/ims.vdex"
        "priv-app/qcrilmsgtunnel/oat/arm64/qcrilmsgtunnel.odex"
        "priv-app/qcrilmsgtunnel/oat/arm64/qcrilmsgtunnel.vdex"
        "app/QtiTelephonyService/oat/arm64/QtiTelephonyService.odex"
        "app/QtiTelephonyService/oat/arm64/QtiTelephonyService.vdex"
        "framework/oat/arm64/qcrilhook.odex"
        "framework/oat/arm64/qcrilhook.odex.fsv_meta"
        "framework/oat/arm64/qcrilhook.vdex"
        "framework/oat/arm64/qcrilhook.vdex.fsv_meta"
    )

    [[ -f "${ims_patch}" ]] || return 0
    for vintf_root in "${vintf_roots[@]}"; do
        [[ -d "${vintf_root}" ]] || continue
        while IFS= read -r -d '' manifest; do
            _port::vintf_ims_hal_matches "${manifest}" hidl && hidl_manifests+=("${manifest}")
            _port::vintf_ims_hal_matches "${manifest}" aidl && aidl_manifests+=("${manifest}")
        done < <(find "${vintf_root}" -type f -name '*.xml' ! -iname '*compatibility*' -print0 2>/dev/null)
    done
    (( ${#hidl_manifests[@]} > 0 && ${#aidl_manifests[@]} == 0 )) || return 0

    target="${image_root}/system_ext/priv-app/ims/ims.apk"
    mkdir -p "$(dirname "${target}")" || return 1
    cp -p -- "${ims_patch}" "${target}" || return 1
    for manifest in "${stale_oat[@]}"; do
        rm -f -- "${image_root}/system_ext/${manifest}" || return 1
    done
    blue "已启用 Qualcomm HIDL IMS 兼容包并清理旧 oat" \
        "Enabled the Qualcomm HIDL IMS compatibility APK and removed stale oat files"
}

_port::selinux_find_compiler() {
    local candidate
    for candidate in \
        "${work_dir:-${PWD}}/tools/host/secilc-3.11" \
        "${work_dir:-${PWD}}/secilc"; do
        [[ -x "${candidate}" ]] && { printf '%s\n' "${candidate}"; return 0; }
    done
    command -v secilc 2>/dev/null || return 1
}

_port::selinux_policy_version() {
    local file="build/portrom/images/vendor/etc/selinux/plat_sepolicy_vers.txt"
    local value="30.0"
    [[ -f "${file}" ]] && value=$(tr -d '[:space:]' < "${file}")
    [[ "${value}" =~ ^[0-9]+\.[0-9]+$ ]] || return 1
    printf '%s\n' "${value}"
}

# Rebuild an ODM precompiled split policy from the extracted framework/vendor
# CIL set.  Callers append only type-checked rules before invoking this helper;
# when no compatible secilc is available, retaining the donor precompiled blob
# is safer than aborting a whole otherwise-valid port.
_port::selinux_compile_split_policy() {
    local output="$1"
    local vendor_policy="$2"
    local vendor_public="$3"
    local system_ext_policy="$4"
    local product_policy="$5"
    local policy_version="$6"
    local system_cil="build/portrom/images/system/system/etc/selinux/plat_sepolicy.cil"
    local system_map_dir="build/portrom/images/system/system/etc/selinux/mapping"
    local vendor_dir="build/portrom/images/vendor/etc/selinux"
    local system_ext_dir="build/portrom/images/system_ext/etc/selinux"
    local product_dir="build/portrom/images/product/etc/selinux"
    local odm_cil="build/portrom/images/odm/etc/selinux/odm_sepolicy.cil"
    local -a inputs=("${system_cil}" "${system_map_dir}/${policy_version}.cil" "${vendor_policy}")
    [[ -f "${vendor_public}" ]] && inputs+=("${vendor_public}")
    [[ -f "${system_map_dir}/${policy_version}.compat.cil" ]] && inputs+=("${system_map_dir}/${policy_version}.compat.cil")
    [[ -f "${system_ext_policy}" ]] && inputs+=("${system_ext_policy}")
    [[ -f "${system_ext_dir}/mapping/${policy_version}.cil" ]] && inputs+=("${system_ext_dir}/mapping/${policy_version}.cil")
    [[ -f "${product_policy}" ]] && inputs+=("${product_policy}")
    [[ -f "${product_dir}/mapping/${policy_version}.cil" ]] && inputs+=("${product_dir}/mapping/${policy_version}.cil")
    [[ -f "${odm_cil}" ]] && inputs+=("${odm_cil}")
    local compiler
    compiler="$(_port::selinux_find_compiler)" || return 2
    "${compiler}" -m -M true -G -N -c "${policy_version%%.*}" \
        -o "${output}" -f /dev/null "${inputs[@]}"
}

_port::patch_performance_sepolicy() {
    case "${port_android_version:-}" in 15|16|17) ;; *) return 0 ;; esac
    case "${base_device_family:-}" in OPSM8250|OPSM8350) ;; *) return 0 ;; esac

    local image_root="build/portrom/images"
    local vendor_dir="${image_root}/vendor/etc/selinux"
    local system_ext_dir="${image_root}/system_ext/etc/selinux"
    local product_dir="${image_root}/product/etc/selinux"
    local odm_dir="${image_root}/odm/etc/selinux"
    local vendor_cil="${vendor_dir}/vendor_sepolicy.cil"
    local vendor_debug_cil="${vendor_dir}/vendor_sepolicy_debug.cil"
    local system_ext_cil="${system_ext_dir}/system_ext_sepolicy.cil"
    local system_ext_debug_cil="${system_ext_dir}/system_ext_sepolicy_debug.cil"
    local product_cil="${product_dir}/product_sepolicy.cil"
    local product_debug_cil="${product_dir}/product_sepolicy_debug.cil"
    local vendor_public="${vendor_dir}/plat_pub_versioned.cil"
    local vendor_public_debug="${vendor_dir}/plat_pub_versioned_debug.cil"
    [[ -f "${vendor_cil}" && -f "${vendor_debug_cil}" ]] || return 0
    grep -qE '^\(type hal_oplus_performance_aidl\)$' "${vendor_cil}" || return 0
    grep -qE '^\(type hal_oplus_performance_aidl_service\)$' "${vendor_cil}" || return 0
    grep -qE '^\(type hal_oplus_performance_aidl\)$' "${vendor_debug_cil}" || return 0
    grep -qE '^\(type hal_oplus_performance_aidl_service\)$' "${vendor_debug_cil}" || return 0

    local -a rules=(
        '(allow oplus_phonemanager_app hal_oplus_performance_aidl_service (service_manager (find)))'
        '(allow oplus_phonemanager_app hal_oplus_performance_aidl (binder (call transfer)))'
        '(allow hal_oplus_performance_aidl oplus_phonemanager_app (binder (transfer)))'
        '(allow oplus_phonemanager_app hal_oplus_performance_aidl (fd (use)))'
    )
    local target rule
    # Only add the dedicated-domain relationship when the domain exists in
    # both policy variants.  Android 17 still receives the radio compatibility
    # rules below even when a donor uses generic priv_app for PhoneManager.
    local domain_prod=false domain_debug=false candidate
    for candidate in "${system_ext_cil}" "${product_cil}" "${vendor_public}"; do
        [[ -f "${candidate}" ]] && grep -qE '^\(type oplus_phonemanager_app\)$' "${candidate}" && domain_prod=true
    done
    for candidate in "${system_ext_debug_cil}" "${product_debug_cil}" "${vendor_public_debug}"; do
        [[ -f "${candidate}" ]] && grep -qE '^\(type oplus_phonemanager_app\)$' "${candidate}" && domain_debug=true
    done
    if [[ "${domain_prod}" == true && "${domain_debug}" == true ]]; then
        for target in "${vendor_cil}" "${vendor_debug_cil}"; do
            for rule in "${rules[@]}"; do
                grep -qF -- "${rule}" "${target}" || printf '%s\n' "${rule}" >> "${target}" || return 1
            done
        done
    fi

    if [[ "${port_android_version}" == 17 ]]; then
        local -a radio_rules=(
            '(allow rild system_prop (file (read getattr map open)))'
            '(allow rild oplus_nw_exported_system_prop (file (read getattr map open)))'
            '(allow rild system_oplus_radio_prop (file (read getattr map open)))'
            '(allow rild vendor_ims_prop (property_service (set)))'
            '(allow rild vendor_ims_prop (file (read getattr map open)))'
            '(allow rild system_data_root_file (dir (write add_name remove_name search getattr open)))'
            '(allow rild system_data_root_file (file (write create getattr open)))'
            '(allow rild cache_file (dir (read write add_name remove_name search getattr open)))'
            '(allow rild cache_file (file (read write create getattr open)))'
            '(allow rild cache_file (lnk_file (read getattr open)))'
        )
        for target in "${vendor_cil}" "${vendor_debug_cil}"; do
            for rule in "${radio_rules[@]}"; do
                grep -qF -- "${rule}" "${target}" || printf '%s\n' "${rule}" >> "${target}" || return 1
            done
        done
    fi

    local policy_version compiler prod_tmp debug_tmp
    policy_version="$(_port::selinux_policy_version)" || return 0
    compiler="$(_port::selinux_find_compiler 2>/dev/null)" || {
        yellow "未找到兼容 secilc，保留 donor 预编译策略" "Compatible secilc unavailable; keeping donor precompiled policy"
        return 0
    }
    mkdir -p "${odm_dir}" || return 1
    prod_tmp=$(mktemp "${odm_dir}/.precompiled_sepolicy.XXXXXX") || return 1
    debug_tmp=$(mktemp "${odm_dir}/.precompiled_sepolicy_debug.XXXXXX") || { rm -f "${prod_tmp}"; return 1; }
    if ! "${compiler}" -m -M true -G -N -c "${policy_version%%.*}" \
        -o "${prod_tmp}" -f /dev/null \
        "${image_root}/system/system/etc/selinux/plat_sepolicy.cil" \
        "${image_root}/system/system/etc/selinux/mapping/${policy_version}.cil" \
        "${vendor_cil}" "${vendor_public}" "${system_ext_cil}" "${product_cil}" \
        "${image_root}/odm/etc/selinux/odm_sepolicy.cil" 2>/dev/null; then
        rm -f "${prod_tmp}" "${debug_tmp}"
        yellow "性能策略预编译失败，保留 donor 策略" "Performance policy precompile failed; keeping donor policy"
        return 0
    fi
    if ! "${compiler}" -m -M true -G -N -c "${policy_version%%.*}" \
        -o "${debug_tmp}" -f /dev/null \
        "${image_root}/system/system/etc/selinux/plat_sepolicy.cil" \
        "${image_root}/system/system/etc/selinux/mapping/${policy_version}.cil" \
        "${vendor_debug_cil}" "${vendor_public_debug}" "${system_ext_debug_cil}" "${product_debug_cil}" \
        "${image_root}/odm/etc/selinux/odm_sepolicy.cil" 2>/dev/null; then
        rm -f "${prod_tmp}" "${debug_tmp}"
        yellow "性能 debug 策略预编译失败，保留 donor 策略" "Performance debug policy precompile failed; keeping donor policy"
        return 0
    fi
    mv -f "${prod_tmp}" "${odm_dir}/precompiled_sepolicy" || return 1
    mv -f "${debug_tmp}" "${odm_dir}/precompiled_sepolicy_debug" || return 1
}

_port::patch_display_panel_sepolicy() {
    [[ "${base_product_device:-}" == OP4E5D ]] || return 0
    case "${port_android_version:-}" in 15|16|17) ;; *) return 0 ;; esac
    local image_root="build/portrom/images"
    local vendor_dir="${image_root}/vendor/etc/selinux"
    local vendor_cil="${vendor_dir}/vendor_sepolicy.cil"
    local vendor_debug_cil="${vendor_dir}/vendor_sepolicy_debug.cil"
    [[ -f "${vendor_cil}" && -f "${vendor_debug_cil}" ]] || return 0
    grep -qE '^\(type oplus_hal_displaypanelfeature\)$' "${vendor_cil}" || return 0
    grep -qE '^\(type vendor_qdisplay_service\)$' "${vendor_cil}" || return 0
    grep -qE '^\(type hal_graphics_composer_default\)$' "${vendor_cil}" || return 0

    local -a rules=(
        '(allow oplus_hal_displaypanelfeature vendor_qdisplay_service (service_manager (find)))'
        '(allow oplus_hal_displaypanelfeature hal_graphics_composer_default (binder (call)))'
    )
    local target rule
    for target in "${vendor_cil}" "${vendor_debug_cil}"; do
        for rule in "${rules[@]}"; do
            grep -qF -- "${rule}" "${target}" || printf '%s\n' "${rule}" >> "${target}" || return 1
        done
    done

    local policy_version compiler prod_tmp debug_tmp
    policy_version="$(_port::selinux_policy_version)" || return 0
    compiler="$(_port::selinux_find_compiler 2>/dev/null)" || return 0
    local odm_dir="${image_root}/odm/etc/selinux"
    mkdir -p "${odm_dir}" || return 1
    prod_tmp=$(mktemp "${odm_dir}/.precompiled_sepolicy.XXXXXX") || return 1
    debug_tmp=$(mktemp "${odm_dir}/.precompiled_sepolicy_debug.XXXXXX") || { rm -f "${prod_tmp}"; return 1; }
    if ! _port::selinux_compile_split_policy "${prod_tmp}" "${vendor_cil}" \
        "${vendor_dir}/plat_pub_versioned.cil" \
        "${image_root}/system_ext/etc/selinux/system_ext_sepolicy.cil" \
        "${image_root}/product/etc/selinux/product_sepolicy.cil" "${policy_version}" || \
       ! _port::selinux_compile_split_policy "${debug_tmp}" "${vendor_debug_cil}" \
        "${vendor_dir}/plat_pub_versioned_debug.cil" \
        "${image_root}/system_ext/etc/selinux/system_ext_sepolicy_debug.cil" \
        "${image_root}/product/etc/selinux/product_sepolicy_debug.cil" "${policy_version}"; then
        rm -f "${prod_tmp}" "${debug_tmp}"
        return 0
    fi
    mv -f "${prod_tmp}" "${odm_dir}/precompiled_sepolicy" || return 1
    mv -f "${debug_tmp}" "${odm_dir}/precompiled_sepolicy_debug" || return 1
}
_port::postdata_badging_lines() {
    local apk="$1"
    "${PORT_POSTDATA_AAPT2}" dump badging "${apk}" 2>/dev/null \
        | sed -n -e '/^package: /p' -e '/^overlay: /p' \
            -e '/^sdkVersion:/p' -e '/^targetSdkVersion:/p'
}

_port::postdata_wifi_bool_true() {
    local apk="$1"
    "${PORT_POSTDATA_AAPT2}" dump resources "${apk}" 2>/dev/null | awk '
        /bool\/config_wifiChannelUtilizationOverrideEnabled/ { seen = 1; next }
        seen && /^[[:space:]]*resource / { exit }
        seen && /^[[:space:]]*\(\)[[:space:]]+true[[:space:]]*$/ { found = 1; exit }
        END { exit(found ? 0 : 1) }
    '
}

_port::postdata_backup_once() {
    local source_file="$1"
    local backup_file="$2"

    [[ -f "${source_file}" ]] || return 0
    if [[ ! -e "${backup_file}" ]]; then
        mkdir -p "$(dirname "${backup_file}")" || return 1
        cp -p -- "${source_file}" "${backup_file}" || return 1
    fi
}

_port::postdata_patch_selinux_context_file() {
    local contexts_file="$1"
    local temp_file

    [[ -f "${contexts_file}" ]] || return 1
    temp_file="${contexts_file}.postdata.$$"

    # The old vendor file-contexts generated by the base ROM explicitly label
    # several overlay APKs as vendor_file.  Android 17's zygote and
    # secure_element domains require vendor_overlay_file instead.  Match by
    # basename so both escaped (\.apk) and unescaped input formats work.
    awk '
        BEGIN {
            count = split("FrameworksResTarget_Vendor SecureElementResTarget_Vendor WifiResMainlineTarget WifiResMainlineTarget_spf WifiResTarget WifiResTarget_spf", names, " ");
        }
        {
            for (i = 1; i <= count; ++i) {
                if (index($0, "/vendor/overlay/" names[i]) == 1)
                    sub(/u:object_r:vendor_file:s0[[:space:]]*$/, "u:object_r:vendor_overlay_file:s0");
            }
            print;
        }
    ' "${contexts_file}" > "${temp_file}" || {
        rm -f -- "${temp_file}"
        return 1
    }
    mv -f -- "${temp_file}" "${contexts_file}" || return 1

    # A vendor-specific recursive rule is needed when the platform
    # plat_file_contexts is not consulted for this mixed-ROM vendor tree.
    if ! grep -Fq '/vendor/overlay(/.*)?' "${contexts_file}"; then
        printf '/vendor/overlay(/.*)? u:object_r:vendor_overlay_file:s0\n' >> "${contexts_file}" || return 1
    fi
    if ! grep -Eq '^/dev/ion[[:space:]]' "${contexts_file}"; then
        printf '/dev/ion u:object_r:ion_device:s0\n' >> "${contexts_file}" || return 1
    fi
}

_port::postdata_patch_selinux_contexts() {
    local images_root="$1"
    local backup_root="$2"
    local config_contexts="${images_root}/config/vendor_file_contexts"
    local runtime_contexts="${images_root}/vendor/etc/selinux/vendor_file_contexts"

    if [[ ! -f "${config_contexts}" ]]; then
        error "缺少 vendor_file_contexts，无法修复 EROFS 标签: ${config_contexts}" \
            "vendor_file_contexts is missing; cannot fix EROFS labels: ${config_contexts}"
        return 1
    fi
    _port::postdata_backup_once "${config_contexts}" \
        "${backup_root}/originals/selinux/config_vendor_file_contexts" || return 1
    _port::postdata_patch_selinux_context_file "${config_contexts}" || return 1

    # This file is consumed by later restorecon operations.  Some vendor
    # packages omit it because the platform copy normally supplies the rules;
    # keep that omission non-fatal while still fixing it when present.
    if [[ -f "${runtime_contexts}" ]]; then
        _port::postdata_backup_once "${runtime_contexts}" \
            "${backup_root}/originals/selinux/vendor_file_contexts" || return 1
        _port::postdata_patch_selinux_context_file "${runtime_contexts}" || return 1
    else
        yellow "未找到运行时 vendor_file_contexts，跳过运行时标签补丁" \
            "Runtime vendor_file_contexts is absent; skipping runtime label patch"
    fi
    green "Android 17 SELinux 标签已修复（vendor overlay、/dev/ion）" \
        "Android 17 SELinux labels fixed (vendor overlays and /dev/ion)"
}

_port::postdata_install_omapi_manifest() {
    local images_root="$1"
    local backup_root="$2"
    local source_file="devices/common/android17_compat/odm/etc/vintf/manifest/secure_element_omapi_service.xml"
    local target_file="${images_root}/odm/etc/vintf/manifest/secure_element_omapi_service.xml"

    if [[ ! -f "${source_file}" ]]; then
        error "缺少 Android 17 OMAPI VINTF 片段: ${source_file}" \
            "Android 17 OMAPI VINTF fragment is missing: ${source_file}"
        return 1
    fi
    mkdir -p "$(dirname "${target_file}")" || return 1
    if cmp -s "${source_file}" "${target_file}"; then
        green "android.se.omapi VINTF 声明已存在，保留当前文件" \
            "android.se.omapi VINTF declaration is already present"
        return 0
    fi
    _port::postdata_backup_once "${target_file}" \
        "${backup_root}/originals/odm/etc/vintf/manifest/secure_element_omapi_service.xml" || return 1
    cp -p -- "${source_file}" "${target_file}" || return 1
    if ! grep -Eq '<name>android\.se\.omapi</name>|<name>ISecureElementService</name>|<instance>default</instance>' \
        "${target_file}"; then
        error "安装后的 OMAPI VINTF 片段校验失败" \
            "Installed OMAPI VINTF fragment failed validation"
        return 1
    fi
    green "已补齐 android.se.omapi/ISecureElementService VINTF 声明" \
        "Added android.se.omapi/ISecureElementService VINTF declaration"
}

_port::postdata_disable_incompatible_loc_sys_service() {
    local images_root="$1"
    local backup_root="$2"
    local rc_file="${images_root}/system_ext/etc/init/loc_sys_service.rc"
    local temp_file

    [[ -f "${rc_file}" ]] || {
        yellow "未找到 loc_sys_service.rc，跳过旧 vendor GNSS AIDL 客户端修复" \
            "loc_sys_service.rc is absent; skipping the legacy-vendor GNSS AIDL client fix"
        return 0
    }

    # Android 17's loc_sys_service is only a client of the Qualcomm AIDL
    # extension vendor.qti.gnss.ILocAidlGnss/default.  The reused Android 11
    # vendor supplies the older HIDL services (ILocHidlGnss/gnss_vendor)
    # instead.  Leaving this client enabled makes servicemanager retry a
    # missing lazy service forever, once per second.  Keep the legacy HIDL
    # gnss_service untouched and disable only this optional A17 client.
    if ! grep -Eq '^[[:space:]]+disabled[[:space:]]*$' "${rc_file}" \
        || grep -Eq '^[[:space:]]*start[[:space:]]+loc_sys_service[[:space:]]*$' "${rc_file}" \
        || grep -Eq '^on[[:space:]]+early-boot[[:space:]]*$' "${rc_file}"; then
        _port::postdata_backup_once "${rc_file}" \
            "${backup_root}/originals/system_ext/etc/init/loc_sys_service.rc" || return 1
        temp_file="${rc_file}.postdata.$$"
        awk '
            /^service[[:space:]]+loc_sys_service[[:space:]]/ {
                print
                in_service = 1
                next
            }
            in_service && /^[[:space:]]+disabled[[:space:]]*$/ {
                have_disabled = 1
                print
                next
            }
            in_service && /^[[:space:]]+class[[:space:]]+main[[:space:]]*$/ {
                print
                if (!have_disabled) {
                    print "    disabled"
                    have_disabled = 1
                }
                next
            }
            /^[[:space:]]*on[[:space:]]+early-boot[[:space:]]*$/ {
                print "# Disabled: Android 11 vendor has no Qualcomm GNSS AIDL backend."
                next
            }
            /^[[:space:]]+start[[:space:]]+loc_sys_service[[:space:]]*$/ {
                print "# Disabled: loc_sys_service requires vendor.qti.gnss.ILocAidlGnss/default."
                next
            }
            { print }
            END { exit(have_disabled ? 0 : 1) }
        ' "${rc_file}" > "${temp_file}" || {
            rm -f -- "${temp_file}"
            error "无法禁用不兼容的 loc_sys_service" \
                "Could not disable the incompatible loc_sys_service"
            return 1
        }
        mv -f -- "${temp_file}" "${rc_file}" || return 1
    fi

    if ! grep -Eq '^[[:space:]]+disabled[[:space:]]*$' "${rc_file}" \
        || grep -Eq '^[[:space:]]*start[[:space:]]+loc_sys_service[[:space:]]*$' "${rc_file}" \
        || grep -Eq '^on[[:space:]]+early-boot[[:space:]]*$' "${rc_file}"; then
        error "loc_sys_service 禁用校验失败" \
            "loc_sys_service disable validation failed"
        return 1
    fi
    green "已禁用依赖 AIDL GNSS 的 loc_sys_service，保留旧 HIDL GNSS" \
        "Disabled the AIDL-dependent loc_sys_service; legacy HIDL GNSS remains enabled"
}

_port::postdata_patch_framework_vintf_compat() {
    local images_root="$1"
    local backup_root="$2"
    local matrix_dir="${images_root}/system/system/etc/vintf"
    local fcm5_target="${matrix_dir}/compatibility_matrix.5.xml"
    local device_matrix="${matrix_dir}/compatibility_matrix.device.xml"
    local system_ext_manifest="${images_root}/system_ext/etc/vintf/manifest.xml"
    local fcm5_source=""
    local candidate
    local temp_file
    local need_memtrack=0
    local need_gnss=0
    local -a fcm5_candidates=(
        "devices/common/android17_compat/system/etc/vintf/compatibility_matrix.5.xml"
        "build/ColorOS17_PLK110_17.0.0.1/extracted/system/system/etc/vintf/compatibility_matrix.5.xml"
        "build/portrom_16.0.8/images/system/system/etc/vintf/compatibility_matrix.5.xml"
    )

    [[ -d "${matrix_dir}" ]] || {
        error "缺少 framework VINTF 目录: ${matrix_dir}" \
            "Framework VINTF directory is missing: ${matrix_dir}"
        return 1
    }
    [[ -f "${device_matrix}" ]] || {
        error "缺少 device compatibility matrix: ${device_matrix}" \
            "Device compatibility matrix is missing: ${device_matrix}"
        return 1
    }

    # Android 11 vendor advertises target-level/FCM 5.  Android 17 no longer
    # installs compatibility_matrix.5.xml by default, so VintfObject rejects
    # the vendor before ActivityTaskManager can consider the build consistent.
    if [[ -f "${fcm5_target}" ]]; then
        if ! grep -Eq '<compatibility-matrix[^>]*level="5"' "${fcm5_target}"; then
            error "现有 compatibility_matrix.5.xml 不是 FCM 5 矩阵" \
                "Existing compatibility_matrix.5.xml is not an FCM 5 matrix"
            return 1
        fi
    else
        for candidate in "${fcm5_candidates[@]}"; do
            if [[ -f "${candidate}" ]] && \
                grep -Eq '<compatibility-matrix[^>]*level="5"' "${candidate}"; then
                fcm5_source="${candidate}"
                break
            fi
        done
        if [[ -z "${fcm5_source}" ]]; then
            error "找不到可信的 FCM 5 compatibility matrix 来源" \
                "Could not find a trusted FCM 5 compatibility matrix source"
            return 1
        fi
        _port::postdata_backup_once "${fcm5_target}" \
            "${backup_root}/originals/system/system/etc/vintf/compatibility_matrix.5.xml" || return 1
        mkdir -p "${matrix_dir}" || return 1
        cp -p -- "${fcm5_source}" "${fcm5_target}" || return 1
        if ! grep -Eq '<compatibility-matrix[^>]*level="5"' "${fcm5_target}"; then
            error "安装后的 FCM 5 compatibility matrix 校验失败" \
                "Installed FCM 5 compatibility matrix failed validation"
            return 1
        fi
        green "已补齐 FCM 5 framework compatibility matrix" \
            "Installed the FCM 5 framework compatibility matrix"
    fi

    # The reused vendor boots a 4.19.325 kernel.  A stock V17 FCM 5 matrix
    # only lists the Android R 5.4 kernel, so accepting FCM 5 alone is not
    # enough: VintfObject still rejects the build at boot.  Keep this narrow
    # 4.19.110 requirement alongside the stock entry; the running 4.19.325
    # kernel satisfies it.
    if ! grep -Fq '<kernel version="4.19.110" level="5"/>' "${fcm5_target}"; then
        _port::postdata_backup_once "${fcm5_target}" \
            "${backup_root}/originals/system/system/etc/vintf/compatibility_matrix.5.xml" || return 1
        temp_file="${fcm5_target}.postdata.$$"
        awk '
            !inserted && /<compatibility-matrix[^>]*level="5"/ {
                print
                print "    <!-- The reused Android 11 vendor boots a 4.19.325 kernel. -->"
                print "    <kernel version=\"4.19.110\" level=\"5\"/>"
                inserted = 1
                next
            }
            { print }
            END { exit(inserted ? 0 : 1) }
        ' "${fcm5_target}" > "${temp_file}" || {
            rm -f -- "${temp_file}"
            error "无法在 FCM 5 matrix 中加入 4.19 内核兼容项" \
                "Could not add the 4.19 kernel compatibility entry to FCM 5"
            return 1
        }
        mv -f -- "${temp_file}" "${fcm5_target}" || return 1
    fi

    # The V17 framework matrix omitted the policy version used by this Android
    # 11 vendor.  Keep all newer entries and add only the compatible 30.0 line.
    if ! grep -Fq '<sepolicy-version>30.0</sepolicy-version>' "${device_matrix}"; then
        _port::postdata_backup_once "${device_matrix}" \
            "${backup_root}/originals/system/system/etc/vintf/compatibility_matrix.device.xml" || return 1
        temp_file="${device_matrix}.postdata.$$"
        awk '
            {
                print
                if (!inserted && index($0, "<kernel-sepolicy-version>30</kernel-sepolicy-version>")) {
                    print "        <sepolicy-version>30.0</sepolicy-version>"
                    inserted = 1
                }
            }
            END { exit(inserted ? 0 : 1) }
        ' "${device_matrix}" > "${temp_file}" || {
            rm -f -- "${temp_file}"
            error "无法在 framework matrix 中加入 sepolicy 30.0" \
                "Could not add sepolicy 30.0 to the framework matrix"
            return 1
        }
        mv -f -- "${temp_file}" "${device_matrix}" || return 1
    fi

    [[ -f "${system_ext_manifest}" ]] || {
        error "缺少 system_ext framework manifest: ${system_ext_manifest}" \
            "system_ext framework manifest is missing: ${system_ext_manifest}"
        return 1
    }
    if ! awk '
        /<vendor-ndk>/ { in_ndk = 1 }
        in_ndk && /<version>30<\/version>/ { found = 1 }
        in_ndk && /<\/vendor-ndk>/ { in_ndk = 0 }
        END { exit(found ? 0 : 1) }
    ' "${system_ext_manifest}"; then
        _port::postdata_backup_once "${system_ext_manifest}" \
            "${backup_root}/originals/system_ext/etc/vintf/manifest.xml" || return 1
        temp_file="${system_ext_manifest}.postdata.$$"
        awk '
            !inserted && index($0, "<vendor-ndk>") {
                print "    <vendor-ndk>"
                print "        <version>30</version>"
                print "    </vendor-ndk>"
                inserted = 1
            }
            { print }
            END { exit(inserted ? 0 : 1) }
        ' "${system_ext_manifest}" > "${temp_file}" || {
            rm -f -- "${temp_file}"
            error "无法在 system_ext manifest 中加入 vendor-ndk 30" \
                "Could not add vendor-ndk 30 to the system_ext manifest"
            return 1
        }
        mv -f -- "${temp_file}" "${system_ext_manifest}" || return 1
    fi

    # The reused Android 11 vendor manifest still exposes these HIDL HALs.
    # They are harmless compatibility declarations; the running services stay
    # supplied by the vendor image and are not replaced by an AIDL stub.
    grep -Fq '<name>android.hardware.memtrack</name>' "${device_matrix}" || need_memtrack=1
    grep -Fq '<name>ILocHidlGnss</name>' "${device_matrix}" || need_gnss=1
    if [[ "${need_memtrack}" -eq 1 || "${need_gnss}" -eq 1 ]]; then
        _port::postdata_backup_once "${device_matrix}" \
            "${backup_root}/originals/system/system/etc/vintf/compatibility_matrix.device.xml" || return 1
        temp_file="${device_matrix}.postdata.$$"
        awk -v add_memtrack="${need_memtrack}" -v add_gnss="${need_gnss}" '
            {
                print
                if (!inserted && index($0, "<name>vendor.qti.esepowermanager</name>")) {
                    in_anchor = 1
                }
                if (in_anchor && !inserted && index($0, "</hal>")) {
                    if (add_memtrack == 1) {
                        print "    <hal format=\"hidl\" optional=\"true\">"
                        print "        <name>android.hardware.memtrack</name>"
                        print "        <version>1.0</version>"
                        print "        <interface>"
                        print "            <name>IMemtrack</name>"
                        print "            <instance>default</instance>"
                        print "        </interface>"
                        print "    </hal>"
                    }
                    if (add_gnss == 1) {
                        print "    <hal format=\"hidl\">"
                        print "        <name>vendor.qti.gnss</name>"
                        print "        <version>1.0-2</version>"
                        print "        <version>2.0-1</version>"
                        print "        <version>3.0</version>"
                        print "        <version>4.0-3</version>"
                        print "        <interface>"
                        print "            <name>ILocHidlGnss</name>"
                        print "            <instance>gnss_vendor</instance>"
                        print "        </interface>"
                        print "    </hal>"
                    }
                    inserted = 1
                }
            }
            END { exit(inserted ? 0 : 1) }
        ' "${device_matrix}" > "${temp_file}" || {
            rm -f -- "${temp_file}"
            error "无法在 device compatibility matrix 中加入旧 HAL 兼容项" \
                "Could not add legacy HAL compatibility entries to the device matrix"
            return 1
        }
        mv -f -- "${temp_file}" "${device_matrix}" || return 1
    fi

    if ! grep -Fq '<kernel version="4.19.110" level="5"/>' "${fcm5_target}" \
        || ! grep -Fq '<sepolicy-version>30.0</sepolicy-version>' "${device_matrix}" \
        || ! grep -Fq '<name>android.hardware.memtrack</name>' "${device_matrix}" \
        || ! grep -Fq '<name>ILocHidlGnss</name>' "${device_matrix}"; then
        error "framework VINTF 兼容项最终校验失败" \
            "Final framework VINTF compatibility validation failed"
        return 1
    fi
    green "已加入 Android 11 vendor 的 FCM5/VNDK30 与旧 HAL 兼容项" \
        "Added FCM5/VNDK30 and legacy HAL compatibility for the Android 11 vendor"
}

_port::postdata_patch_nfc_defaults() {
    local images_root="$1"
    local backup_root="$2"
    local prop_file="${images_root}/my_product/build.prop"
    local temp_file

    if [[ ! -f "${prop_file}" ]]; then
        yellow "缺少 my_product/build.prop，跳过 NFC 默认值修复" \
            "my_product/build.prop is missing; skipping NFC default properties"
        return 0
    fi

    _port::postdata_backup_once "${prop_file}" \
        "${backup_root}/originals/my_product/build.prop" || return 1
    temp_file="${prop_file}.postdata.$$"
    awk '
        /^persist\.nfc\.smartcard\.recorder\.enable=/ {
            if (!smartcard_seen++) print "persist.nfc.smartcard.recorder.enable=false"
            next
        }
        /^persist\.nfc\.vendor_debug_enabled=/ {
            if (!vendor_seen++) print "persist.nfc.vendor_debug_enabled=false"
            next
        }
        /^persist\.nfc\.snoop_log_mode=/ {
            if (!snoop_seen++) print "persist.nfc.snoop_log_mode=filtered"
            next
        }
        { print }
        END {
            if (!smartcard_seen) print "persist.nfc.smartcard.recorder.enable=false"
            if (!vendor_seen) print "persist.nfc.vendor_debug_enabled=false"
            if (!snoop_seen) print "persist.nfc.snoop_log_mode=filtered"
        }
    ' "${prop_file}" > "${temp_file}" || {
        rm -f -- "${temp_file}"
        return 1
    }
    mv -f -- "${temp_file}" "${prop_file}" || return 1

    if [[ "$(grep -cFx 'persist.nfc.smartcard.recorder.enable=false' "${prop_file}")" -ne 1 ]] \
        || [[ "$(grep -cFx 'persist.nfc.vendor_debug_enabled=false' "${prop_file}")" -ne 1 ]] \
        || [[ "$(grep -cFx 'persist.nfc.snoop_log_mode=filtered' "${prop_file}")" -ne 1 ]]; then
        error "NFC 默认属性最终校验失败" "Final NFC default property validation failed"
        return 1
    fi
    green "已关闭 NFC 调试/智能卡记录默认值" \
        "Disabled NFC debug and smart-card recording by default"
}

_port::postdata_install_vendor_ueventd_compat() {
    local images_root="$1"
    local backup_root="$2"
    local target_file="${images_root}/vendor/etc/ueventd.rc"
    local legacy_file="${images_root}/vendor/ueventd.rc"
    local target_size=0

    # Android 17's system/etc/ueventd.rc imports /vendor/etc/ueventd.rc.
    # The SM8250 Android 11 vendor keeps the actual rules at /vendor/ueventd.rc
    # instead, so without this tiny bridge all legacy /dev permissions and
    # firmware_directories rules are silently skipped by ueventd.
    if [[ ! -f "${legacy_file}" ]]; then
        yellow "缺少 legacy vendor/ueventd.rc，跳过 ueventd 兼容桥" \
            "Legacy vendor/ueventd.rc is missing; skipping the ueventd bridge"
        return 0
    fi

    if [[ -f "${target_file}" ]]; then
        if grep -Eq '^[[:space:]]*import[[:space:]]+/vendor/ueventd\.rc[[:space:]]*$' \
            "${target_file}"; then
            green "vendor ueventd 兼容桥已存在" \
                "Vendor ueventd compatibility bridge already exists"
            return 0
        fi
        target_size="$(stat -c '%s' "${target_file}" 2>/dev/null || printf '0')"
        # Do not replace a complete modern vendor ueventd file.  Only replace
        # the old empty/short stub; a full file already contains its own rules.
        if [[ "${target_size}" -gt 1024 ]]; then
            yellow "保留现有完整 vendor/etc/ueventd.rc（${target_size} bytes）" \
                "Keeping existing complete vendor/etc/ueventd.rc (${target_size} bytes)"
            return 0
        fi
    fi

    _port::postdata_backup_once "${target_file}" \
        "${backup_root}/originals/vendor/etc/ueventd.rc" || return 1
    mkdir -p "$(dirname "${target_file}")" || return 1
    printf '%s\n' \
        '# Android 17 reads vendor uevent rules from /vendor/etc/ueventd.rc.' \
        '# Import the legacy vendor layout used by this Android 11 device image.' \
        'import /vendor/ueventd.rc' > "${target_file}" || return 1
    chmod 0644 "${target_file}" || return 1
    if ! grep -Eq '^import /vendor/ueventd\.rc$' "${target_file}"; then
        error "vendor ueventd 兼容桥写入失败" \
            "Failed to install vendor ueventd compatibility bridge"
        return 1
    fi
    green "已补齐 vendor/etc/ueventd.rc → /vendor/ueventd.rc 兼容桥" \
        "Added vendor/etc/ueventd.rc -> /vendor/ueventd.rc compatibility bridge"
}

_port::postdata_replace_audio_effect_center() {
    local images_root="$1"
    local backup_root="$2"
    local source_img=""
    local source_type=""
    local extract_root=""
    local source_dir=""
    local target_dir="${images_root}/my_product/app/AudioEffectCenter"
    local candidate
    local source_file
    local relative_file
    local target_file
    local -a source_candidates=()
    local gettype_tool="${tools_dir:-bin/Linux/x86_64}/gettype"
    local erofs_tool="${tools_dir:-bin/Linux/x86_64}/extract.erofs"
    local imgextractor="${work_dir:-.}/bin/imgextractor/imgextractor.py"

    # stage 30 keeps the unmodified port image in the cache/version directory;
    # the copy in images/ is also available before stage 50 repacks it.
    [[ -n "${portrom_cache_dir:-}" ]] && \
        source_candidates+=("${portrom_cache_dir%/}/my_product.img")
    [[ -n "${version_name:-}" ]] && \
        source_candidates+=("build/${version_name}/my_product.img")
    source_candidates+=("${images_root}/my_product.img")
    for candidate in "${source_candidates[@]}"; do
        if [[ -f "${candidate}" ]]; then
            source_img="${candidate}"
            break
        fi
    done
    if [[ -z "${source_img}" ]]; then
        yellow "找不到原始 Android 17 my_product.img，跳过 AudioEffectCenter 修复" \
            "Original Android 17 my_product.img is unavailable; skipping AudioEffectCenter fix"
        return 0
    fi
    if [[ ! -x "${gettype_tool}" || ! -x "${erofs_tool}" ]]; then
        error "缺少 EROFS 提取工具，无法恢复 Android 17 AudioEffectCenter" \
            "EROFS extraction tools are missing; cannot restore Android 17 AudioEffectCenter"
        return 1
    fi

    extract_root="$(mktemp -d "${TMPDIR:-/tmp}/a17-audio-effect.XXXXXX")" || return 1
    source_type="$(${gettype_tool} -i "${source_img}" 2>/dev/null || true)"
    case "${source_type}" in
        erofs)
            if ! "${erofs_tool}" -X /app/AudioEffectCenter -i "${source_img}" \
                -o "${extract_root}" >/dev/null 2>&1; then
                rm -rf -- "${extract_root}"
                error "提取 Android 17 AudioEffectCenter 失败: ${source_img}" \
                    "Failed to extract Android 17 AudioEffectCenter: ${source_img}"
                return 1
            fi
            ;;
        ext)
            if [[ ! -f "${imgextractor}" ]] || ! python3 "${imgextractor}" \
                "${source_img}" "${extract_root}" >/dev/null 2>&1; then
                rm -rf -- "${extract_root}"
                error "提取 ext my_product.img 失败: ${source_img}" \
                    "Failed to extract ext my_product.img: ${source_img}"
                return 1
            fi
            ;;
        *)
            rm -rf -- "${extract_root}"
            error "无法识别 my_product.img 文件系统: ${source_type:-unknown}" \
                "Unknown my_product.img filesystem: ${source_type:-unknown}"
            return 1
            ;;
    esac

    source_dir="${extract_root}/my_product/app/AudioEffectCenter"
    # imgextractor/extract.erofs versions in older tool bundles differ on
    # whether the partition basename is included in the output root.
    if [[ ! -d "${source_dir}" && -d "${extract_root}/app/AudioEffectCenter" ]]; then
        source_dir="${extract_root}/app/AudioEffectCenter"
    fi
    if [[ ! -f "${source_dir}/AudioEffectCenter.apk" ]]; then
        rm -rf -- "${extract_root}"
        yellow "Android 17 my_product 未提供 AudioEffectCenter，保留移植包当前版本" \
            "Android 17 my_product has no AudioEffectCenter; keeping the port version"
        return 0
    fi

    # Preserve every old file before replacing the directory, including stale
    # odex/vdex files that could otherwise be paired with the wrong APK.
    if [[ -d "${target_dir}" ]]; then
        while IFS= read -r -d '' source_file; do
            relative_file="${source_file#${target_dir}/}"
            _port::postdata_backup_once "${source_file}" \
                "${backup_root}/originals/my_product/app/AudioEffectCenter/${relative_file}" || {
                rm -rf -- "${extract_root}"
                return 1
            }
        done < <(find "${target_dir}" -type f -print0)
    fi
    rm -rf -- "${target_dir}" || { rm -rf -- "${extract_root}"; return 1; }
    mkdir -p "$(dirname "${target_dir}")" || { rm -rf -- "${extract_root}"; return 1; }
    cp -a -- "${source_dir}" "${target_dir}" || { rm -rf -- "${extract_root}"; return 1; }
    target_file="${target_dir}/AudioEffectCenter.apk"
    if ! cmp -s "${source_dir}/AudioEffectCenter.apk" "${target_file}"; then
        rm -rf -- "${extract_root}"
        error "AudioEffectCenter APK 替换后校验失败" \
            "AudioEffectCenter APK failed verification after replacement"
        return 1
    fi
    rm -rf -- "${extract_root}"
    green "已恢复 Android 17 AudioEffectCenter APK/vdex（来源 ${source_img}）" \
        "Restored Android 17 AudioEffectCenter APK/vdex from ${source_img}"
}

_port::postdata_map_dir() {
    local root="$1"
    local partition="$2"
    local candidate

    case "${partition}" in
        system)
            for candidate in \
                "${root}/system/system/etc/selinux/mapping" \
                "${root}/system/etc/selinux/mapping" \
                "${root}/system" \
                "${root}/etc/selinux/mapping" \
                "${root}"; do
                [[ -d "${candidate}" ]] && { printf '%s\n' "${candidate}"; return 0; }
            done
            ;;
        system_ext|product)
            for candidate in \
                "${root}/${partition}/etc/selinux/mapping" \
                "${root}/${partition}" \
                "${root}/etc/selinux/mapping"; do
                [[ -d "${candidate}" ]] && { printf '%s\n' "${candidate}"; return 0; }
            done
            ;;
    esac
    return 1
}

_port::postdata_map_file_valid() {
    local file="$1"
    [[ -s "${file}" ]] || return 1
    grep -Eq '^\((type|typeattribute|typeattributeset|expandtypeattribute|roletype|allow|neverallow)[[:space:]]' "${file}"
}

_port::postdata_map_pair_valid() {
    local dir="$1"
    _port::postdata_map_file_valid "${dir}/30.0.cil" \
        && _port::postdata_map_file_valid "${dir}/30.0.compat.cil"
}

_port::postdata_map_source_root() {
    local explicit_source="${PORT_SELINUX_MAP_SOURCE:-}"
    local candidate
    local system_dir
    local system_ext_dir
    local product_dir

    if [[ -n "${explicit_source}" ]]; then
        system_dir="$(_port::postdata_map_dir "${explicit_source}" system 2>/dev/null || true)"
        system_ext_dir="$(_port::postdata_map_dir "${explicit_source}" system_ext 2>/dev/null || true)"
        product_dir="$(_port::postdata_map_dir "${explicit_source}" product 2>/dev/null || true)"
        if [[ -n "${system_dir}" ]] && _port::postdata_map_pair_valid "${system_dir}" \
            && [[ -n "${system_ext_dir}" && -f "${system_ext_dir}/30.0.cil" ]] \
            && [[ -n "${product_dir}" && -f "${product_dir}/30.0.cil" ]]; then
            printf '%s\n' "${explicit_source}"
            return 0
        fi
        return 1
    fi

    # The common mapping is the local default; it belongs in a separately
    # provenance-reviewed device resource bundle. Workspace locations below
    # are only migration fallbacks. Never rename the Android 17 31.0 mapping
    # to 30.0 or guess the ABI from an unverified A17 system policy.
    local -a candidates=(
        "devices/common/selinux_mapping/android11_vendor"
    )
    shopt -s nullglob
    candidates+=(devices/common/selinux_mapping/android16)
    candidates+=(devices/*/selinux_mapping/android16)
    shopt -u nullglob

    for candidate in "${candidates[@]}"; do
        system_dir="$(_port::postdata_map_dir "${candidate}" system 2>/dev/null || true)"
        system_ext_dir="$(_port::postdata_map_dir "${candidate}" system_ext 2>/dev/null || true)"
        product_dir="$(_port::postdata_map_dir "${candidate}" product 2>/dev/null || true)"
        if [[ -n "${system_dir}" ]] && _port::postdata_map_pair_valid "${system_dir}" \
            && [[ -n "${system_ext_dir}" && -f "${system_ext_dir}/30.0.cil" ]] \
            && [[ -n "${product_dir}" && -f "${product_dir}/30.0.cil" ]]; then
            printf '%s\n' "${candidate}"
            return 0
        fi
    done
    return 1
}

_port::postdata_install_mapping() {
    local source_root="$1"
    local images_root="$2"
    local backup_root="$3"
    local partition="$4"
    local required="$5"
    local source_dir
    local target_dir
    local name
    local source_file
    local target_file
    local backup_file
    local installed=0
    local file_required

    source_dir="$(_port::postdata_map_dir "${source_root}" "${partition}" 2>/dev/null || true)"
    case "${partition}" in
        system) target_dir="${images_root}/system/system/etc/selinux/mapping" ;;
        system_ext|product) target_dir="${images_root}/${partition}/etc/selinux/mapping" ;;
        *) return 1 ;;
    esac

    for name in 30.0.cil 30.0.compat.cil; do
        file_required="${required}"
        [[ "${name}" == "30.0.compat.cil" && "${partition}" != "system" ]] && file_required="false"
        target_file="${target_dir}/${name}"
        if _port::postdata_map_file_valid "${target_file}"; then
            blue "已存在有效 ${partition}/${name}，保留当前文件" \
                "Keeping existing valid ${partition}/${name}"
            continue
        fi

        source_file="${source_dir}/${name}"
        if [[ -z "${source_dir}" || ! -f "${source_file}" ]] \
            || ! _port::postdata_map_file_valid "${source_file}"; then
            if [[ "${file_required}" == "true" ]]; then
                error "缺少可信 SELinux mapping: ${partition}/${name}" \
                    "Missing trusted SELinux mapping: ${partition}/${name}"
                return 1
            fi
            yellow "来源没有可用 ${partition}/${name}，跳过可选文件" \
                "No usable ${partition}/${name} in source; skipping optional file"
            continue
        fi

        backup_file="${backup_root}/originals/${partition}/${name}"
        _port::postdata_backup_once "${target_file}" "${backup_file}" || return 1
        mkdir -p "${target_dir}" || return 1
        cp -p -- "${source_file}" "${target_file}" || return 1
        if ! _port::postdata_map_file_valid "${target_file}"; then
            error "安装后 SELinux mapping 校验失败: ${target_file}" \
                "SELinux mapping validation failed after install: ${target_file}"
            return 1
        fi
        installed=1
        blue "补齐 ${partition}/${name}（来源 ${source_root}）" \
            "Installed ${partition}/${name} from ${source_root}"
    done

    return 0
}

_port::postdata_prepare_mapping() {
    local images_root="$1"
    local backup_root="$2"
    local source_root

    source_root="$(_port::postdata_map_source_root 2>/dev/null || true)"
    if [[ -z "${source_root}" ]]; then
        error "找不到可信 Android 16/30.0 SELinux mapping 来源" \
            "Could not find a trusted Android 16/30.0 SELinux mapping source"
        return 1
    fi
    blue "使用 SELinux 30.0 mapping 来源: ${source_root}" \
        "Using SELinux 30.0 mapping source: ${source_root}"

    _port::postdata_install_mapping "${source_root}" "${images_root}" "${backup_root}" system true || return 1
    _port::postdata_install_mapping "${source_root}" "${images_root}" "${backup_root}" system_ext true || return 1
    _port::postdata_install_mapping "${source_root}" "${images_root}" "${backup_root}" product true || return 1

    for _postdata_map in \
        "${images_root}/system/system/etc/selinux/mapping/30.0.cil" \
        "${images_root}/system/system/etc/selinux/mapping/30.0.compat.cil"; do
        if ! _port::postdata_map_file_valid "${_postdata_map}"; then
            error "最终 system 30.0 mapping 无效: ${_postdata_map}" \
                "Final system 30.0 mapping is invalid: ${_postdata_map}"
            return 1
        fi
        _postdata_map_hash="$(port_sha256_file "${_postdata_map}")" || return 1
        blue "SELinux mapping SHA-256: ${_postdata_map_hash}" \
            "SELinux mapping SHA-256: ${_postdata_map_hash}"
    done
}

_port::stage_postdata_compat() {
    local images_root="build/portrom/images"
    local backup_root="build/diagnostics/boot-postdata-compat-pipeline"
    local qspm_policy="${images_root}/vendor/etc/seccomp_policy/qspm.policy"
    local wifi_rro="${images_root}/system_ext/overlay/OplusWifiResource.apk"
    local framework_res="${images_root}/system/system/framework/framework-res.apk"
    local oplus_framework_res="${images_root}/system_ext/framework/oplus-framework-res.apk"
    local apkeditor_jar="bin/apktool/APKEditor.jar"
    local aapt2="otatools/bin/aapt2"
    local apksigner="otatools/bin/apksigner"
    local signing_key="otatools/key/testkey.pk8"
    local signing_cert="otatools/key/testkey.x509.pem"
    local private_tmp=""
    local decoded_dir=""
    local unsigned_apk=""
    local signed_apk=""
    local original_meta=""
    local rebuilt_meta=""
    local bool_file=""
    local qspm_tmp=""

    case "${port_android_version:-}" in
        16|17) ;;
        *)
            blue "跳过 Android 16/17 开机后兼容修复（当前 Android ${port_android_version:-unknown}）" \
                "Skipping Android 16/17 post-data compatibility fixes (Android ${port_android_version:-unknown})"
            return 0
            ;;
    esac

    PORT_POSTDATA_AAPT2="${aapt2}"
    export PORT_POSTDATA_AAPT2
    mkdir -p "${backup_root}/originals" || return 1

    # The mapping, VINTF, seccomp, SELinux, NFC, and AudioEffectCenter changes
    # are Android-17-only.  Android 16 needs only the isolated Wi-Fi RRO
    # compatibility flag below, so it keeps its original vendor/framework
    # compatibility surface.
    if [[ "${port_android_version:-}" == "17" ]]; then
        _port::postdata_prepare_mapping "${images_root}" "${backup_root}" || return 1

        # These fixes must happen before stage 50 runs fspatch.py/contextpatch.py
        # and repacks the EROFS images.
        _port::postdata_install_omapi_manifest "${images_root}" "${backup_root}" || return 1
        _port::postdata_disable_incompatible_loc_sys_service "${images_root}" "${backup_root}" || return 1
        _port::postdata_patch_framework_vintf_compat "${images_root}" "${backup_root}" || return 1
        _port::postdata_patch_nfc_defaults "${images_root}" "${backup_root}" || return 1
        _port::postdata_install_vendor_ueventd_compat "${images_root}" "${backup_root}" || return 1
        _port::postdata_patch_selinux_contexts "${images_root}" "${backup_root}" || return 1
        _port::postdata_replace_audio_effect_center "${images_root}" "${backup_root}" || return 1

        # Modify the qspm policy only when the target file exists; its absence
        # means this vendor has no such policy file.
        if [[ -f "${qspm_policy}" ]]; then
            _port::postdata_backup_once "${qspm_policy}" "${backup_root}/originals/qspm.policy" || return 1
            if ! grep -qxF 'renameat2: 1' "${qspm_policy}"; then
                qspm_tmp="${qspm_policy}.postdata.$$"
                if grep -qxF 'renameat: 1' "${qspm_policy}"; then
                    awk '{ print; if ($0 == "renameat: 1") print "renameat2: 1" }' \
                        "${qspm_policy}" > "${qspm_tmp}" || return 1
                else
                    cat "${qspm_policy}" > "${qspm_tmp}" || return 1
                    printf '\nrenameat2: 1\n' >> "${qspm_tmp}"
                fi
                mv -f -- "${qspm_tmp}" "${qspm_policy}" || return 1
            fi
            if [[ "$(grep -cFx 'renameat2: 1' "${qspm_policy}")" -ne 1 ]]; then
                error "qspm.policy 中 renameat2: 1 数量异常" "qspm.policy has an invalid renameat2 rule count"
                return 1
            fi
            green "Android 17 qspm 已放行 renameat2" "Android 17 qspm allows renameat2"
        else
            yellow "未找到 ${qspm_policy}，跳过 qspm 修复" \
                "${qspm_policy} not found; skipping qspm fix"
        fi
    fi

    # The Wi-Fi resource guard is shared by Android 16 and Android 17.  It is
    # intentionally the only compatibility edit applied to Android 16 here.
    if [[ ! -f "${wifi_rro}" ]]; then
        yellow "未找到 OplusWifiResource.apk，跳过 Wi-Fi RRO 修复" \
            "OplusWifiResource.apk not found; skipping Wi-Fi RRO fix"
        return 0
    fi
    if [[ ! -f "${framework_res}" || ! -f "${oplus_framework_res}" ]]; then
        yellow "缺少 Android 17 framework 资源，跳过 Wi-Fi RRO 修复" \
            "Android 17 framework resources are incomplete; skipping Wi-Fi RRO fix"
        return 0
    fi
    for _postdata_tool in "${apkeditor_jar}" "${aapt2}" "${apksigner}" "${signing_key}" "${signing_cert}"; do
        if [[ ! -f "${_postdata_tool}" ]]; then
            error "缺少 Android 17 RRO 工具或签名材料: ${_postdata_tool}" \
                "Missing Android 17 RRO tool or signing material: ${_postdata_tool}"
            return 1
        fi
    done

    _port::postdata_backup_once "${wifi_rro}" "${backup_root}/originals/OplusWifiResource.apk" || return 1
    original_meta="$(_port::postdata_badging_lines "${wifi_rro}")"
    if [[ -z "${original_meta}" ]]; then
        error "无法读取 OplusWifiResource.apk 的 manifest 元数据" \
            "Could not read OplusWifiResource.apk manifest metadata"
        return 1
    fi

    # An already-fixed APK is verified directly to avoid repeated decode and
    # re-sign; keeps the stage idempotent.
    if _port::postdata_wifi_bool_true "${wifi_rro}"; then
        if ! "${apksigner}" verify --verbose "${wifi_rro}" >/dev/null 2>&1; then
            error "现有 OplusWifiResource.apk 签名验证失败" \
                "Existing OplusWifiResource.apk failed signature verification"
            return 1
        fi
        green "OplusWifiResource.apk 已是兼容配置，跳过重编译" \
            "OplusWifiResource.apk already has the compatibility flag"
        return 0
    fi

    private_tmp="$(mktemp -d "${TMPDIR:-/tmp}/postdata-compat.XXXXXX")" || return 1
    decoded_dir="${private_tmp}/OplusWifiResource"
    unsigned_apk="${private_tmp}/OplusWifiResource-unsigned.apk"
    signed_apk="${private_tmp}/OplusWifiResource-signed.apk"

    if ! java -jar "${apkeditor_jar}" d -f -t xml \
        -i "${wifi_rro}" -o "${decoded_dir}" \
        -framework "${framework_res}" -framework "${oplus_framework_res}"; then
        error "使用 APKEditor 解码 OplusWifiResource.apk 失败" \
            "APKEditor failed to decode OplusWifiResource.apk"
        return 1
    fi

    bool_file="$(grep -R -l --include='bools.xml' 'config_wifiChannelUtilizationOverrideEnabled' \
        "${decoded_dir}" 2>/dev/null | head -n 1)"
    if [[ -z "${bool_file}" ]]; then
        error "RRO 中不存在 config_wifiChannelUtilizationOverrideEnabled" \
            "RRO does not contain config_wifiChannelUtilizationOverrideEnabled"
        return 1
    fi
    sed -E -i \
        's#(<bool[[:space:]]+name="config_wifiChannelUtilizationOverrideEnabled">)[^<]*(</bool>)#\1true\2#' \
        "${bool_file}"
    if ! grep -Eq '<bool[[:space:]]+name="config_wifiChannelUtilizationOverrideEnabled">true</bool>' "${bool_file}"; then
        error "写入 Wi-Fi channel utilization 兼容值失败" \
            "Failed to set the Wi-Fi channel utilization compatibility value"
        return 1
    fi

    if ! java -jar "${apkeditor_jar}" b -f \
        -i "${decoded_dir}" -o "${unsigned_apk}" \
        -framework "${framework_res}" -framework "${oplus_framework_res}"; then
        error "使用 APKEditor 重编译 OplusWifiResource.apk 失败" \
            "APKEditor failed to rebuild OplusWifiResource.apk"
        return 1
    fi
    if ! "${apksigner}" sign --in "${unsigned_apk}" --out "${signed_apk}" \
        --key "${signing_key}" --cert "${signing_cert}" \
        --v1-signing-enabled true --v2-signing-enabled true --v3-signing-enabled true; then
        error "OplusWifiResource.apk 签名失败" "Failed to sign OplusWifiResource.apk"
        return 1
    fi
    if ! "${apksigner}" verify --verbose "${signed_apk}"; then
        error "重编译后的 OplusWifiResource.apk 签名验证失败" \
            "Rebuilt OplusWifiResource.apk failed signature verification"
        return 1
    fi
    if ! _port::postdata_wifi_bool_true "${signed_apk}"; then
        error "重编译 APK 的 Wi-Fi 兼容值不是 true" \
            "Rebuilt APK does not contain the Wi-Fi compatibility value"
        return 1
    fi
    rebuilt_meta="$(_port::postdata_badging_lines "${signed_apk}")"
    if [[ "${original_meta}" != "${rebuilt_meta}" ]]; then
        error "RRO manifest/overlay 元数据发生变化，拒绝替换" \
            "RRO manifest/overlay metadata changed; refusing replacement"
        return 1
    fi

    chmod --reference="${wifi_rro}" "${signed_apk}" 2>/dev/null || true
    cp -p -- "${signed_apk}" "${wifi_rro}" || return 1
    green "Android 17 OplusWifiResource.apk 修复并签名完成" \
        "Android 17 OplusWifiResource.apk rebuilt and signed"
    return 0
}
_port::stage_patch_teesim() {
    local src="devices/common/oplus_identity_teesim"
    local out="build/portrom/images"
    local teesim_root="$out/system/system/oplus/teesim"

    # The native payload is not built by the ROM pipeline itself.  It is
    # produced by the reference Gradle/CMake build (see
    # work/teesim-port/README.md) and copied here as an opaque zip so the
    # ROM tree stays reproducible without a Rust/NDK toolchain.
    if [[ ! -d "${src}" || ! -f "${src}/payload.zip" ]]; then
        yellow "TEE simulator payload not found; skipping native integration" \
            "TEE simulator payload not found; skipping native integration"
        return 0
    fi

    local payload
    payload=$(mktemp -d "${TMPDIR:-/tmp}/teesim-payload.XXXXXX")
    trap 'rm -rf -- "${payload}"' RETURN
    unzip -qo "${src}/payload.zip" -d "${payload}"

    local arch="arm64-v8a"
    if [[ ! -d "${payload}/${arch}" ]]; then
        yellow "TEE simulator payload has no ${arch} tree" \
            "TEE simulator payload has no ${arch} tree"
        return 0
    fi

    local sys="$out/system/system"
    local bin="$sys/bin"
    local lib="$sys/lib64"
    local etc="$sys/etc"
    local rc="$etc/init"
    mkdir -p "${bin}" "${lib}" "${etc}/init" "${teesim_root}"

    # The ROM daemon starts only when the user (or the port defaults) enables
    # the property.  Persist it in every build.prop so the mode survives
    # reboots without depending on a KernelSU module.
    for prop in "${out}/product/etc/build.prop" \
                "${out}/system/system/build.prop" \
                "${out}/system_ext/etc/build.prop"; do
        if [[ -f "${prop}" ]]; then
            grep -q "^persist.sys.oplus_teesim.enable=" "${prop}" \
                || printf 'persist.sys.oplus_teesim.enable=true\n' >> "${prop}"
        fi
    done

    # Native interceptor, injector and the daemon launcher.  The Injector
    # class resolves $moduleDir/<abi>/inject and /libteesim_keymint.so, so the
    # payload keeps the reference <abi>/ layout under /system/oplus/teesim.
    # Merge into the ABI directory when the stage is resumed.  `cp -a
    # src dest` would create a nested arm64-v8a/arm64-v8a tree on the second
    # pass, leaving stale duplicate payload entries in fs_config.
    mkdir -p "${teesim_root}/${arch}"
    cp -a "${payload}/${arch}/." "${teesim_root}/${arch}/"
    # EROFS honours system_fs_config over the host mode bits.  The source zip
    # carries executable bits for the injector and UDS helper, but an older
    # materialised fs_config in a resumed build may pin them to 0644; normalize
    # the entries below before stage 50 runs fspatch/mkfs.
    local system_fs_config="${out}/config/system_fs_config"
    if [[ -f "${system_fs_config}" ]]; then
        for executable in \
            "system/system/oplus/teesim/${arch}/inject" \
            "system/system/oplus/teesim/${arch}/teesim-uds"; do
            if grep -qE "^${executable}[[:space:]]" "${system_fs_config}"; then
                sed -i -E "s|^${executable}[[:space:]].*|${executable} 0 0 0755|" "${system_fs_config}"
            else
                printf '%s 0 0 0755\n' "${executable}" >> "${system_fs_config}"
            fi
        done
    fi
    # keystore2's default linker namespace only admits system library paths.
    # Keep the canonical payload under /system/oplus for the WebUI/diagnostic
    # view, and mirror the API 31+ interceptor to /system/lib64 where
    # android_dlopen_ext can resolve it after FD transfer.
    install -m 0644 "${payload}/${arch}/libteesim_keymint.so" \
        "${lib}/libteesim_keymint.so"
    # The daemon dlopens libteesim_logcat.so into its own process; the
    # app_process linker namespace only searches /system/lib64 etc., not
    # /system/oplus/teesim/<abi>.  Mirror the library to the standard path so
    # System.loadLibrary resolves it without namespace changes.
    install -m 0644 "${payload}/${arch}/libteesim_logcat.so" \
        "${lib}/libteesim_logcat.so"
    install -m 0755 "${payload}/${arch}/teesim-uds" \
        "${bin}/oplus-teesim-uds"

    # The control daemon is a dex launched by app_process.  It is kept next
    # to the launcher script rather than in an APK so the boot service can
    # exec it without PackageManager involvement.
    if [[ -f "${payload}/classes.dex" ]]; then
        install -m 0644 "${payload}/classes.dex" \
            "${teesim_root}/classes.dex"
    fi

    # Default config: the daemon reads profiles from /data/adb/teesim.  Seed
    # the same default used by the reference module so GMS/Play Store are
    # covered as soon as the user drops a keybox in place.
    if [[ -f "${payload}/config.default.json" ]]; then
        install -m 0644 "${payload}/config.default.json" \
            "${etc}/oplus-teesim-config.json"
    fi

    # A small launcher that behaves like the reference module's module/daemon:
    # it execs app_process with the dex path and passes the payload root as
    # both the app-process classpath directory and the Injector module dir.
    cat > "${bin}/oplus-teesim-daemon" <<'EOF'
#!/system/bin/sh
# Launches the TEE simulator control daemon (see stage 475).
case "$(getprop persist.sys.oplus_teesim.enable)" in
    true|1) ;;
    *) echo "teesim: disabled via persist.sys.oplus_teesim.enable" >&2; exit 0 ;;
esac
ROOT=/system/oplus/teesim
if [ ! -f "$ROOT/classes.dex" ]; then
  echo "teesim: classes.dex missing under $ROOT" >&2
  exit 1
fi
# init services run with an empty environment.  app_process needs the boot
# image paths (BOOTCLASSPATH etc.) to load framework classes such as the
# BouncyCastle provider; without them framework class init fails with an
# opaque NPE at App.main.  announce the standard paths explicitly.
ANDROID_ROOT=/system
ANDROID_DATA=/data
ANDROID_STORAGE=/storage
ANDROID_ART_ROOT=/apex/com.android.art
ANDROID_I18N_ROOT=/apex/com.android.i18n
ANDROID_TZDATA_ROOT=/apex/com.android.tzdata
BOOTCLASSPATH=/apex/com.android.art/javalib/core-oj.jar:/apex/com.android.art/javalib/core-libart.jar:/apex/com.android.art/javalib/okhttp.jar:/apex/com.android.art/javalib/bouncycastle.jar:/apex/com.android.art/javalib/apache-xml.jar:/system/framework/framework.jar:/system/framework/framework-graphics.jar:/system/framework/framework-location.jar:/system/framework/ext.jar:/system/framework/telephony-common.jar:/system/framework/voip-common.jar:/system/framework/ims-common.jar:/system/framework/framework-ondeviceintelligence-platform.jar:/system/framework/framework-nfc.jar:/system/framework/tcmiface.jar:/system/framework/qcom.fmradio.jar:/system/framework/QPerformance.jar:/system/framework/UxPerformance.jar:/system/framework/WfdCommon.jar:/system/framework/oplus-framework.jar:/system/framework/subsystem-framework.jar:/apex/com.android.i18n/javalib/core-icu4j.jar:/apex/com.android.adservices/javalib/framework-adservices.jar:/apex/com.android.adservices/javalib/framework-sdksandbox.jar:/apex/com.android.appsearch/javalib/framework-appsearch.jar:/apex/com.android.configinfrastructure/javalib/framework-configinfrastructure.jar:/apex/com.android.conscrypt/javalib/conscrypt.jar:/apex/com.android.crashrecovery/javalib/framework-crashrecovery.jar:/apex/com.android.devicelock/javalib/framework-devicelock.jar:/apex/com.android.healthfitness/javalib/framework-healthfitness.jar:/apex/com.android.ipsec/javalib/android.net.ipsec.ike.jar:/apex/com.android.media/javalib/updatable-media.jar:/apex/com.android.mediaprovider/javalib/framework-mediaprovider.jar:/apex/com.android.mediaprovider/javalib/framework-pdf.jar:/apex/com.android.mediaprovider/javalib/framework-pdf-v.jar:/apex/com.android.mediaprovider/javalib/framework-photopicker.jar:/apex/com.android.ondevicepersonalization/javalib/framework-ondevicepersonalization.jar:/apex/com.android.os.statsd/javalib/framework-statsd.jar:/apex/com.android.permission/javalib/framework-permission.jar:/apex/com.android.permission/javalib/framework-permission-s.jar:/apex/com.android.profiling/javalib/framework-profiling.jar:/apex/com.android.scheduling/javalib/framework-scheduling.jar:/apex/com.android.sdkext/javalib/framework-sdkextensions.jar:/apex/com.android.tethering/javalib/framework-connectivity.jar:/apex/com.android.tethering/javalib/framework-connectivity-b.jar:/apex/com.android.tethering/javalib/framework-connectivity-t.jar:/apex/com.android.tethering/javalib/framework-tethering.jar:/apex/com.android.uwb/javalib/framework-ranging.jar:/apex/com.android.uwb/javalib/framework-uwb.jar:/apex/com.android.virt/javalib/framework-virtualization.jar:/apex/com.android.wifi/javalib/framework-wifi.jar
DEX2OATBOOTCLASSPATH=/apex/com.android.art/javalib/core-oj.jar:/apex/com.android.art/javalib/core-libart.jar:/apex/com.android.art/javalib/okhttp.jar:/apex/com.android.art/javalib/bouncycastle.jar:/apex/com.android.art/javalib/apache-xml.jar:/system/framework/framework.jar:/system/framework/framework-graphics.jar:/system/framework/framework-location.jar:/system/framework/ext.jar:/system/framework/telephony-common.jar:/system/framework/voip-common.jar:/system/framework/ims-common.jar:/system/framework/framework-ondeviceintelligence-platform.jar:/system/framework/framework-nfc.jar:/system/framework/tcmiface.jar:/system/framework/qcom.fmradio.jar:/system/framework/QPerformance.jar:/system/framework/UxPerformance.jar:/system/framework/WfdCommon.jar:/system/framework/oplus-framework.jar:/system/framework/subsystem-framework.jar:/apex/com.android.i18n/javalib/core-icu4j.jar
export ANDROID_ROOT ANDROID_DATA ANDROID_STORAGE ANDROID_ART_ROOT ANDROID_I18N_ROOT ANDROID_TZDATA_ROOT BOOTCLASSPATH DEX2OATBOOTCLASSPATH
exec /system/bin/app_process -Djava.class.path="$ROOT/classes.dex" "$ROOT" \
  --nice-name=teesim org.matrix.teesim.App "$ROOT"
EOF
    chmod 0755 "${bin}/oplus-teesim-daemon"

    # SELinux policy for the injected library and control socket.  The
    # keystore2 domain already exists in the platform policy; the extra
    # rules mirror the reference module's sepolicy.rule but are written as
    # CIL additions to the port policy so they survive a port build.
    local plat_cil="${out}/system/system/etc/selinux/plat_sepolicy.cil"
    if [[ -f "${plat_cil}" ]]; then
        _port::teesim_append_cil "${plat_cil}" || return 1
    fi
    # ColorOS labels /data/format_unclear and related public data under the
    # system_ext policy.  Keep that one allow in system_ext rather than
    # referencing a system_ext type from plat (split-policy compilation rejects
    # that direction on Android 15+).
    local system_ext_cil="${out}/system_ext/etc/selinux/system_ext_sepolicy.cil"
    if [[ -f "${system_ext_cil}" ]]; then
        _port::teesim_append_system_ext_cil "${system_ext_cil}" || return 1
    fi

    # stage 50 reuses the precompiled policy shipped in odm when its
    # framework-input hash files match.  A resumed/materialised tree can
    # retain hashes from the donor image, so keep the copies in odm aligned
    # with the framework partitions that are actually flashed.  This is only
    # a hash-file synchronization; the policy binaries themselves are rebuilt
    # by the normal policy repack step after this stage.
    local hash_src hash_dst
    for hash_src in \
        "${out}/system/system/etc/selinux/plat_sepolicy_and_mapping.sha256" \
        "${out}/system_ext/etc/selinux/system_ext_sepolicy_and_mapping.sha256" \
        "${out}/product/etc/selinux/product_sepolicy_and_mapping.sha256" \
        "${out}/system_ext/etc/selinux/plat_sepolicy_and_mapping_debug.sha256" \
        "${out}/system_ext/etc/selinux/system_ext_sepolicy_and_mapping_debug.sha256" \
        "${out}/product/etc/selinux/product_sepolicy_and_mapping_debug.sha256"; do
        [[ -f "${hash_src}" ]] || continue
        case "${hash_src}" in
            */plat_sepolicy_and_mapping.sha256)
                hash_dst="${out}/odm/etc/selinux/precompiled_sepolicy.plat_sepolicy_and_mapping.sha256" ;;
            */system_ext_sepolicy_and_mapping.sha256)
                hash_dst="${out}/odm/etc/selinux/precompiled_sepolicy.system_ext_sepolicy_and_mapping.sha256" ;;
            */product_sepolicy_and_mapping.sha256)
                hash_dst="${out}/odm/etc/selinux/precompiled_sepolicy.product_sepolicy_and_mapping.sha256" ;;
            */plat_sepolicy_and_mapping_debug.sha256)
                hash_dst="${out}/odm/etc/selinux/precompiled_sepolicy_debug.plat_sepolicy_and_mapping.sha256" ;;
            */system_ext_sepolicy_and_mapping_debug.sha256)
                hash_dst="${out}/odm/etc/selinux/precompiled_sepolicy_debug.system_ext_sepolicy_and_mapping.sha256" ;;
            */product_sepolicy_and_mapping_debug.sha256)
                hash_dst="${out}/odm/etc/selinux/precompiled_sepolicy_debug.product_sepolicy_and_mapping.sha256" ;;
            *) continue ;;
        esac
        [[ -f "${hash_dst}" ]] && cp -f "${hash_src}" "${hash_dst}"
    done

    # File contexts.  The EROFS config file uses doubled paths
    # (/system/system/...) because mkfs mounts the tree at system/; the
    # runtime plat_file_contexts uses single paths.  Keep both in sync so
    # restorecon cannot undo the su_exec label on the daemon.
    local image_contexts="${out}/config/system_file_contexts"
    local runtime_contexts="${out}/system/system/etc/selinux/plat_file_contexts"
    for spec in "config:${image_contexts}:/system/system" \
                "runtime:${runtime_contexts}:/system"; do
        local spec_rest="${spec#*:}"
        local ctx_file="${spec_rest%%:*}"
        local ctx_prefix="${spec_rest##*:}"
        [[ -f "${ctx_file}" ]] || continue
        for entry in \
            "${ctx_prefix}/bin/oplus-teesim-uds" \
            "${ctx_prefix}/oplus/teesim(/.*)?" \
            "${ctx_prefix}/etc/oplus-teesim-config.json"; do
            if ! grep -Fq "${entry}" "${ctx_file}"; then
                printf '%s u:object_r:system_file:s0\n' "${entry}" \
                    >> "${ctx_file}"
            fi
        done
        # The daemon transitions into its dedicated domain; SELinux entrypoint
        # requires the executable itself to carry the matching exec type.
        local daemon_path="${ctx_prefix}/bin/oplus-teesim-daemon"
        if grep -Fq "${daemon_path} u:object_r:su_exec:s0" "${ctx_file}"; then
            sed -i \
                "s#${daemon_path} u:object_r:su_exec:s0#${daemon_path} u:object_r:oplus_teesim_daemon_exec:s0#" \
                "${ctx_file}"
        elif ! grep -Fq "${daemon_path}" "${ctx_file}"; then
            printf '%s u:object_r:oplus_teesim_daemon_exec:s0\n' "${daemon_path}" \
                >> "${ctx_file}"
        fi
    done

    # Launch once keystore2 is up.  The daemon is a root service that
    # harvests attestation, injects the interceptor into keystore2, and
    # pushes the resolved profile over the control socket.  It is disabled by
    # default: an explicit property enables it so a stock port boots
    # unchanged and the user opts into TEE simulation.
    cat > "${rc}/oplus_teesim.rc" <<'EOF'
service oplus_teesim /system/bin/oplus-teesim-daemon
    class main
    user root
    group root
    seclabel u:r:oplus_teesim_daemon:s0
    disabled

on property:sys.boot_completed=1
    start oplus_teesim
EOF

    blue "TEE simulator native payload installed" \
        "TEE simulator native payload installed"
}

# Append a small CIL block to the platform policy.  Re-running this stage is
# idempotent because the block carries a unique marker comment.
_port::teesim_append_cil() {
    local cil_file="$1"
    if grep -Fq "oplus_teesim" "${cil_file}"; then
        # The stage can be re-entered against an already materialised output
        # tree (for example when only the payload changed).  Preserve the type
        # declarations above, but backfill rules added in later revisions.
        local rule
        for rule in \
            '(allow oplus_teesim_daemon apex_art_data_file (file (execute)))' \
            '(allow oplus_teesim_daemon keystore_service (service_manager (find)))' \
            '(allow oplus_teesim_daemon package_service (service_manager (find)))' \
            '(allow oplus_teesim_daemon display_service (service_manager (find)))' \
            '(allow oplus_teesim_daemon activity_service (service_manager (find)))' \
            '(allow oplus_teesim_daemon settings_service (service_manager (find)))' \
            '(allow oplus_teesim_daemon user_service (service_manager (find)))' \
            '(allow oplus_teesim_daemon statsdw_socket (sock_file (write)))' \
            '(allow oplus_teesim_daemon keystore (process (ptrace getattr getpgid sigchld sigkill sigstop signal)))' \
            '(allow oplus_teesim_daemon proc (dir (search getattr open read)))' \
            '(allow oplus_teesim_daemon keystore (dir (search getattr open read)))' \
            '(allow oplus_teesim_daemon keystore (file (read getattr map open)))' \
            '(allow oplus_teesim_daemon keystore (unix_dgram_socket (sendto)))' \
            '(allow oplus_teesim_daemon self (capability (sys_ptrace)))' \
            '(allow oplus_teesim_daemon self (unix_dgram_socket (create bind connect sendto recvfrom read write getattr setattr getopt setopt shutdown)))' \
            '(allow oplus_teesim_daemon adb_data_file (dir (add_name setattr)))'; do
            grep -Fq "${rule}" "${cil_file}" || printf '%s\n' "${rule}" >> "${cil_file}"
        done
        return 0
    fi
    cat >> "${cil_file}" <<'EOF'

; ---- oplus TEE simulator (stage 475) ----
; Dedicated daemon domain, modelled on oplus_identity_updater so init can
; transition into it.  The daemon runs app_process and needs the same platform
; access a system helper has, plus the control-socket/keystore relationships.
(type oplus_teesim_daemon)
(roletype object_r oplus_teesim_daemon)
(type oplus_teesim_daemon_exec)
(roletype object_r oplus_teesim_daemon_exec)
(allow init oplus_teesim_daemon (process (transition)))
(allow init oplus_teesim_daemon (process2 (nosuid_transition)))
(allow init oplus_teesim_daemon_exec (file (read getattr map execute open)))
(allow oplus_teesim_daemon oplus_teesim_daemon_exec (file (entrypoint open read execute execute_no_trans getattr map)))
(allow init oplus_teesim_daemon (process (noatsecure rlimitinh siginh dyntransition)))
(typetransition init oplus_teesim_daemon_exec process oplus_teesim_daemon)

; app_process and standard shell/toolbox executables.
(allow oplus_teesim_daemon zygote_exec (file (read execute open execute_no_trans map getattr)))
(allow oplus_teesim_daemon shell_exec (file (read execute open execute_no_trans map)))
(allow oplus_teesim_daemon toolbox_exec (file (read execute open execute_no_trans map)))
(allow oplus_teesim_daemon system_file (dir (search getattr open read)))
(allow oplus_teesim_daemon system_file (file (read open getattr map execute execute_no_trans)))
(allow oplus_teesim_daemon property_type (file (read open getattr map)))

; Data dir, bridge config and log files.
(allow oplus_teesim_daemon adb_data_file (dir (read search getattr open write create rename remove_name)))
(allow oplus_teesim_daemon adb_data_file (file (read write create getattr setattr open unlink rename map)))
(allow oplus_teesim_daemon adb_data_file (sock_file (read write open getattr setattr create unlink)))
(allow oplus_teesim_daemon system_data_file (dir (read search getattr open)))
(allow oplus_teesim_daemon apex_module_data_file (dir (read search getattr open)))
(allow oplus_teesim_daemon apex_module_data_file (file (read open getattr map)))
(allow oplus_teesim_daemon apex_art_data_file (dir (read search getattr open)))
(allow oplus_teesim_daemon apex_art_data_file (file (read open getattr map execute)))
(allow oplus_teesim_daemon apex_info_file (file (read getattr map open)))
(allow oplus_teesim_daemon servicemanager (binder (call transfer)))
(allow servicemanager oplus_teesim_daemon (binder (transfer)))
(allow oplus_teesim_daemon default_android_service (service_manager (find)))
(allow oplus_teesim_daemon system_server (binder (call transfer)))
(allow system_server oplus_teesim_daemon (binder (transfer)))
(allow oplus_teesim_daemon self (capability (dac_read_search dac_override chown fowner fsetid setgid setuid)))

; Control socket to the legacy keystore daemon.
(allow oplus_teesim_daemon keystore (unix_stream_socket (connectto)))
(allow oplus_teesim_daemon keystore_data_file (dir (search getattr open)))
(allow oplus_teesim_daemon keystore_data_file (sock_file (read write open getattr)))
(allow oplus_teesim_daemon self (unix_stream_socket (connectto)))

; Log reader via liblog; settings command for the identity bridge.
(allow oplus_teesim_daemon logd (unix_stream_socket (connectto)))
(allow oplus_teesim_daemon logdr_socket (sock_file (write)))
(allow oplus_teesim_daemon system_prop (file (read getattr map open)))
(allow oplus_teesim_daemon keystore_service (service_manager (find)))
(allow oplus_teesim_daemon package_service (service_manager (find)))
(allow oplus_teesim_daemon display_service (service_manager (find)))
(allow oplus_teesim_daemon activity_service (service_manager (find)))
(allow oplus_teesim_daemon settings_service (service_manager (find)))
(allow oplus_teesim_daemon user_service (service_manager (find)))
(allow oplus_teesim_daemon statsdw_socket (sock_file (write)))
(allow oplus_teesim_daemon keystore (process (ptrace getattr getpgid sigchld sigkill sigstop signal)))
(allow oplus_teesim_daemon proc (dir (search getattr open read)))
(allow oplus_teesim_daemon keystore (dir (search getattr open read)))
(allow oplus_teesim_daemon keystore (file (read getattr map open)))
(allow oplus_teesim_daemon keystore (unix_dgram_socket (sendto)))
(allow oplus_teesim_daemon self (capability (sys_ptrace)))
(allow oplus_teesim_daemon self (unix_dgram_socket (create bind connect sendto recvfrom read write getattr setattr getopt setopt shutdown)))
(allow oplus_teesim_daemon adb_data_file (dir (add_name setattr)))

; keystore binds the control socket; crash_dump ptrace is the injector.
(allow keystore self (unix_stream_socket (connectto)))
(allow keystore keystore_data_file (dir (getattr search)))
(allow keystore keystore_data_file (sock_file (read write open getattr setattr create unlink)))
(allow keystore oplus_teesim_daemon (unix_stream_socket (connectto)))
(allow crash_dump keystore (process (ptrace sigchld sigkill sigstop signal getattr getpgid)))
(allow keystore adb_data_file (file (read map getattr open)))
(typeattributeset domain (oplus_teesim_daemon))
(typeattributeset file_type (oplus_teesim_daemon_exec))
(typeattributeset exec_type (oplus_teesim_daemon_exec))
(typeattributeset system_file_type (oplus_teesim_daemon_exec))
EOF
}

# Rules for types declared by system_ext policy.  Keep this separate from the
# platform block because split sepolicy does not permit plat CIL to reference
# a system_ext-private type such as oplus_public_data_file.
_port::teesim_append_system_ext_cil() {
    local cil_file="$1"
    if grep -Fq "oplus TEE simulator system_ext additions" "${cil_file}"; then
        return 0
    fi
    cat >> "${cil_file}" <<'EOF'

; ---- oplus TEE simulator system_ext additions (stage 475) ----
(allow oplus_teesim_daemon oplus_public_data_file (dir (search getattr open read)))
EOF
}
