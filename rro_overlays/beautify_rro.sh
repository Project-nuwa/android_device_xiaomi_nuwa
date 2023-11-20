#!/usr/bin/bash
#
# Copyright (C) 2022 The LineageOS Project
#
# SPDX-License-Identifier: Apache-2.0
#

DEBUG=0
if [[ ${DEBUG} != 0 ]]; then
    log="/dev/tty"
else
    log="/dev/null"
fi

if [[ -z ${1} ]]; then
    echo usage: beautify_rro.sh /path/to/rro_source [/path/to/original_source]
    exit
fi

RRO_DIR="${1}"
SRC_DIR=""
targetPackage=$(sed -n "s/.*targetPackage=\"\([a-z.]\+\)\".*/\1/gp" ${RRO_DIR}/AndroidManifest.xml)
if [[ ! -z ${2} ]]; then
    SRC_DIR=${2}
else
    echo "Guessing source for $targetPackage" > ${log}

    case "${targetPackage}" in
    "android")
        SRC_DIR=../../../frameworks/base/core/res
        ;;
    "com.android.systemui")
        SRC_DIR=../../../frameworks/base/packages/SystemUI
        ;;
    *)
        SRC_DIR=$(rg "package=\"${targetPackage}\"" ../../../packages/ | grep -v install-in-user-type | sed "s/://g" | awk '{print $1}' | sed "s/\(..\/..\/..\/[a-zA-Z0-9]\+\/[a-zA-Z0-9]\+\/[a-zA-Z0-9]\+\).*/\1/g" | head -1)
        ;;
    esac

    echo "Guessed source: $SRC_DIR" > ${log}
fi

if [[ -z ${SRC_DIR} ]] || [[ ! -d ${SRC_DIR} ]]; then
    echo "Could not find source for $targetPackage, last guess: ${SRC_DIR}"
    exit
else
    echo "Using source: $SRC_DIR" > ${log}
fi

# Create a temporary working directory
TMPDIR=$(mktemp -d)

for file in $(find ${RRO_DIR}/res -name "*.xml"); do
    if ! xmllint --format ${file} &> /dev/null; then
        echo "${file} is not a valid XML, skipping"
        continue
    fi

    # Create a backup
    cp ${file} ${TMPDIR}/$(basename ${file}).bak

    for name in $(grep -r "name" ${file} | sed "s/[<>]/ /g" | sed "s/\"/\\\\\"/g" | awk '{print $2}'); do
        if ! grep -qr ${name} ${SRC_DIR}; then
            echo "Did not find resource ${name}" > ${log}
            continue
        fi

        src_path=$(grep -r ${name} ${SRC_DIR} | grep -v symbols.xml | sed "s/://g" | awk '{print $1}' | head -1)
        if [[ ! -f ${src_path} ]]; then
            echo "src_path: $src_path does not exist, skipping" > ${log}
            continue
        fi

        line=$(sed -n "/.*${name}.*/=" ${src_path} | head -1)
        if [[ -z $(sed -n "$(expr ${line} - 1)p" ${src_path} | sed -n "/.*-->.*/p") ]]; then
            echo "Did not find ending string before ${name} in ${src_path}" > ${log}
            continue
        fi

        line=$(sed -n "/.*${name}.*/=" ${file} | head -1)
        if [[ ! -z $(sed -n "$(expr ${line} - 1)p" ${file} | sed -n "/.*-->.*/p") ]]; then
            echo "There is already a comment for ${name} in ${file}, skipping" > ${log}
            continue
        fi

        # Drop everything after our item
        sed "/${name}/q" ${src_path} > "${TMPDIR}"/before.txt

        # Search for the last "<!--" before the item and write from there up to the item
        sed -n "$(sed -n /\<\!--/= "${TMPDIR}"/before.txt | tail -1),\$p" "${TMPDIR}"/before.txt | head -n -1  > "${TMPDIR}"/comment.txt

        # Add empty line above comment, skip if first line in this file as in line 3
        line=$(sed -n "/.*${name}.*/=" ${file})
        if [[ ! ${line} -eq 3 ]]; then
            sed -i '1s/^/\n/' "${TMPDIR}"/comment.txt
        fi

        # Insert the comment above the item
        sed -i "$(expr ${line} - 1) r ${TMPDIR}/comment.txt" ${file}
    done

    if ! xmllint --format ${file} &> /dev/null; then
        echo "We broke ${file}. Restoring backup"
        cp ${TMPDIR}/$(basename ${file}).bak ${file}
    fi
    rm ${TMPDIR}/$(basename ${file}).bak
done

# Clear the temporary working directory
rm -rf "${TMPDIR}"