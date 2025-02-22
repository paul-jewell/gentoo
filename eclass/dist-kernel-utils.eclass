# Copyright 2020-2023 Gentoo Authors
# Distributed under the terms of the GNU General Public License v2

# @ECLASS: dist-kernel-utils.eclass
# @MAINTAINER:
# Distribution Kernel Project <dist-kernel@gentoo.org>
# @AUTHOR:
# Michał Górny <mgorny@gentoo.org>
# @SUPPORTED_EAPIS: 7 8
# @BLURB: Utility functions related to Distribution Kernels
# @DESCRIPTION:
# This eclass provides various utility functions related to Distribution
# Kernels.

# @ECLASS_VARIABLE: KERNEL_IUSE_SECUREBOOT
# @PRE_INHERIT
# @DEFAULT_UNSET
# @DESCRIPTION:
# If set to a non-null value, inherits secureboot.eclass
# and allows signing of generated kernel images.

# @ECLASS_VARIABLE: KERNEL_EFI_ZBOOT
# @DEFAULT_UNSET
# @DESCRIPTION:
# If set to a non-null value, it is assumed the kernel was built with
# CONFIG_EFI_ZBOOT enabled. This effects the name of the kernel image on
# arm64 and riscv. Mainly useful for sys-kernel/gentoo-kernel-bin.

if [[ ! ${_DIST_KERNEL_UTILS} ]]; then

case ${EAPI} in
	7|8) ;;
	*) die "${ECLASS}: EAPI ${EAPI:-0} not supported" ;;
esac

inherit toolchain-funcs

if [[ ${KERNEL_IUSE_SECUREBOOT} ]]; then
	inherit secureboot
fi

# @FUNCTION: dist-kernel_build_initramfs
# @USAGE: <output> <version>
# @DESCRIPTION:
# Build an initramfs for the kernel.  <output> specifies the absolute
# path where initramfs will be created, while <version> specifies
# the kernel version, used to find modules.
#
# Note: while this function uses dracut at the moment, other initramfs
# variants may be supported in the future.
dist-kernel_build_initramfs() {
	debug-print-function ${FUNCNAME} "${@}"

	[[ ${#} -eq 2 ]] || die "${FUNCNAME}: invalid arguments"
	local output=${1}
	local version=${2}

	local rel_image_path=$(dist-kernel_get_image_path)
	local image=${output%/*}/${rel_image_path##*/}

	local args=(
		--force
		# if uefi=yes is used, dracut needs to locate the kernel image
		--kernel-image "${image}"

		# positional arguments
		"${output}" "${version}"
	)

	ebegin "Building initramfs via dracut"
	dracut "${args[@]}"
	eend ${?} || die -n "Building initramfs failed"
}

# @FUNCTION: dist-kernel_get_image_path
# @DESCRIPTION:
# Get relative kernel image path specific to the current ${ARCH}.
dist-kernel_get_image_path() {
	case ${ARCH} in
		amd64|x86)
			echo arch/x86/boot/bzImage
			;;
		arm64|riscv)
			if [[ ${KERNEL_EFI_ZBOOT} ]]; then
				echo arch/${ARCH}/boot/vmlinuz.efi
			else
				echo arch/${ARCH}/boot/Image.gz
			fi
			;;
		loong)
			if [[ ${KERNEL_EFI_ZBOOT} ]]; then
				echo arch/loongarch/boot/vmlinuz.efi
			else
				echo arch/loongarch/boot/vmlinux.elf
			fi
			;;
		arm)
			echo arch/arm/boot/zImage
			;;
		hppa|ppc|ppc64|sparc)
			# https://www.kernel.org/doc/html/latest/powerpc/bootwrapper.html
			# ./ is required because of ${image_path%/*}
			# substitutions in the code
			echo ./vmlinux
			;;
		*)
			die "${FUNCNAME}: unsupported ARCH=${ARCH}"
			;;
	esac
}

# @FUNCTION: dist-kernel_install_kernel
# @USAGE: <version> <image> <system.map>
# @DESCRIPTION:
# Install kernel using installkernel tool.  <version> specifies
# the kernel version, <image> full path to the image, <system.map>
# full path to System.map.
dist-kernel_install_kernel() {
	debug-print-function ${FUNCNAME} "${@}"

	[[ ${#} -eq 3 ]] || die "${FUNCNAME}: invalid arguments"
	local version=${1}
	local image=${2}
	local map=${3}

	if has_version "<=sys-kernel/installkernel-gentoo-7"; then
		# if dracut is used in uefi=yes mode, initrd will actually
		# be a combined kernel+initramfs UEFI executable.  we can easily
		# recognize it by PE magic (vs cpio for a regular initramfs)
		local initrd=${image%/*}/initrd
		local magic
		[[ -s ${initrd} ]] && read -n 2 magic < "${initrd}"
		if [[ ${magic} == MZ ]]; then
			einfo "Combined UEFI kernel+initramfs executable found"
			# install the combined executable in place of kernel
			image=${initrd%/*}/uki.efi
			mv "${initrd}" "${image}" || die

			if [[ ${KERNEL_IUSE_SECUREBOOT} ]]; then
				# Ensure the uki is signed if dracut hasn't already done so.
				secureboot_sign_efi_file "${image}"
			fi
		fi
	fi

	ebegin "Installing the kernel via installkernel"
	# note: .config is taken relatively to System.map;
	# initrd relatively to bzImage
	ARCH=$(tc-arch-kernel) installkernel "${version}" "${image}" "${map}"
	eend ${?} || die -n "Installing the kernel failed"
}

# @FUNCTION: dist-kernel_reinstall_initramfs
# @USAGE: <kv-dir> <kv-full>
# @DESCRIPTION:
# Rebuild and install initramfs for the specified dist-kernel.
# <kv-dir> is the kernel source directory (${KV_DIR} from linux-info),
# while <kv-full> is the full kernel version (${KV_FULL}).
# The function will determine whether <kernel-dir> is actually
# a dist-kernel, and whether initramfs was used.
#
# With sys-kernel/installkernel-systemd, or version 8 or greater of
# sys-kernel/installkernel-gentoo, the generation of the initrd via dracut
# is handled by kernel-install instead.
#
# This function is to be used in pkg_postinst() of ebuilds installing
# kernel modules that are included in the initramfs.
dist-kernel_reinstall_initramfs() {
	debug-print-function ${FUNCNAME} "${@}"

	[[ ${#} -eq 2 ]] || die "${FUNCNAME}: invalid arguments"
	local kernel_dir=${1}
	local ver=${2}

	local image_path=${kernel_dir}/$(dist-kernel_get_image_path)
	if [[ ! -f ${image_path} ]]; then
		eerror "Kernel install missing, image not found:"
		eerror "  ${image_path}"
		eerror "Initramfs will not be updated.  Please reinstall your kernel."
		return
	fi

	if has_version "<=sys-kernel/installkernel-gentoo-7"; then
		local initramfs_path=${image_path%/*}/initrd
		if [[ ! -f ${initramfs_path} && ! -f ${initramfs_path%/*}/uki.efi ]]; then
			einfo "No initramfs or uki found at ${image_path}"
			return
		fi

		dist-kernel_build_initramfs "${initramfs_path}" "${ver}"
	fi

	dist-kernel_install_kernel "${ver}" "${image_path}" \
		"${kernel_dir}/System.map"
}

# @FUNCTION: dist-kernel_PV_to_KV
# @USAGE: <pv>
# @DESCRIPTION:
# Convert a Gentoo-style ebuild version to kernel "x.y.z[-rcN]" version.
dist-kernel_PV_to_KV() {
	debug-print-function ${FUNCNAME} "${@}"

	[[ ${#} -ne 1 ]] && die "${FUNCNAME}: invalid arguments"
	local pv=${1}

	local kv=${pv%%_*}
	[[ -z $(ver_cut 3- "${kv}") ]] && kv+=".0"
	[[ ${pv} == *_* ]] && kv+=-${pv#*_}
	echo "${kv}"
}

_DIST_KERNEL_UTILS=1
fi
