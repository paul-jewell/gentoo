# Copyright 1999-2023 Gentoo Authors
# Distributed under the terms of the GNU General Public License v2

EAPI=8

PYTHON_COMPAT=( python3_{10..12} )

inherit gnome2-utils meson python-single-r1 xdg

DESCRIPTION="Simple game launcher written in Python using GTK4 and Libadwaita"
HOMEPAGE="https://github.com/kra-mo/cartridges/"

if [[ "${PV}" == *9999* ]] ; then
	inherit git-r3

	EGIT_REPO_URI="https://github.com/kra-mo/${PN}.git"
else
	SRC_URI="https://github.com/kra-mo/${PN}/archive/v${PV}.tar.gz
		-> ${P}.tar.gz"

	KEYWORDS="~amd64 ~x86"
fi

LICENSE="GPL-3+"
SLOT="0"
REQUIRED_USE="${PYTHON_REQUIRED_USE}"

RDEPEND="
	${PYTHON_DEPS}
	>=gui-libs/libadwaita-1.4.0:1[introspection]
	gui-libs/gtk:4[introspection]
	$(python_gen_cond_dep '
		dev-python/pygobject:3[${PYTHON_USEDEP}]
	')
"
BDEPEND="
	${RDEPEND}
	dev-libs/appstream-glib
	dev-util/blueprint-compiler
	dev-util/desktop-file-utils
"

src_install() {
	meson_src_install

	python_fix_shebang "${ED}/usr/bin"
	python_optimize "${ED}/usr/share/cartridges/cartridges"
}

pkg_postinst() {
	gnome2_schemas_update
	xdg_pkg_postinst
}

pkg_postrm() {
	gnome2_schemas_update
	xdg_pkg_postrm
}
