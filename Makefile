.DEFAULT_GOAL := help

help: ## Tampilkan daftar perintah
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'

preflight: ## Cek server siap atau belum
	bash scripts/preflight.sh

up: ## Jalankan Stalwart
	bash scripts/bootstrap.sh

plan: ## Render dan terapkan konfigurasi deklaratif
	bash scripts/render-plan.sh && bash scripts/apply-plan.sh

dns: ## Cetak record DNS yang harus dipasang
	bash scripts/dns-records.sh

verify: ## Uji kirim, terima, dan autentikasi email
	bash scripts/verify.sh

logs: ## Ikuti log container
	docker compose logs -f --tail=100

test: ## Jalankan unit test skrip
	bats tests/

.PHONY: help preflight up plan dns verify logs test
