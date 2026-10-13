# External-module build of the genpd provider for the live device tree's
# /soc/mm/power-domain@0 (compatible "sprd,vpu-pd", label "vpu_pd_top").
#
# The DPU (sprd,qogirn6pro-dpu) and both DSI hosts declare `power-domains = <&vpu_pd_top>`, so
# without this provider they probe with -EPROBE_DEFER forever and the panel never comes up. The ZTE
# kernel tree ships no driver for that compatible -- it only exists in the realme tree, from which
# sprd_vpu_pw_domain.c is copied verbatim (md5 ba6d6416f8491cbfd172877ca6581c71, GPL-2.0-only).
obj-m += sprd-vpu-pd.o
sprd-vpu-pd-objs := sprd_vpu_pw_domain.o
