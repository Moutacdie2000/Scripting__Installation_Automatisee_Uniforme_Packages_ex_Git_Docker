# Makefile — raccourcis pour le script d'onboarding Linux.
#
# Cibles principales :
#   make help      Affiche cette aide.
#   make dry-run   Exécute onboard.sh en mode --dry-run (aucune modification).
#   make run       Exécute réellement onboard.sh (peut demander sudo).
#   make lint      Vérifie tous les scripts shell avec shellcheck.
#
# Variables surchargées en ligne de commande, ex. :
#   make run PROFILE=minimal YES=1
#   make dry-run PROFILE=dev GIT_NAME="Jane Doe" GIT_EMAIL=jane@example.com

SHELL        := /usr/bin/env bash
SCRIPT       := ./onboard.sh
SHELL_FILES  := onboard.sh lib/log.sh lib/detect-os.sh lib/packages.sh

# Paramètres par défaut (modifiables : make run PROFILE=dev YES=1 ...).
PROFILE      ?= dev
GIT_NAME     ?=
GIT_EMAIL    ?=
YES          ?=

# Construction dynamique des arguments optionnels.
PROFILE_ARG  := --profile $(PROFILE)
YES_ARG      := $(if $(YES),--yes,)
GITNAME_ARG  := $(if $(GIT_NAME),--git-name "$(GIT_NAME)",)
GITEMAIL_ARG := $(if $(GIT_EMAIL),--git-email "$(GIT_EMAIL)",)
COMMON_ARGS  := $(PROFILE_ARG) $(YES_ARG) $(GITNAME_ARG) $(GITEMAIL_ARG)

.DEFAULT_GOAL := help

.PHONY: help dry-run run lint

help: ## Affiche la liste des cibles disponibles
	@echo "Cibles disponibles :"
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) \
		| awk 'BEGIN {FS = ":.*?## "} {printf "  \033[36m%-12s\033[0m %s\n", $$1, $$2}'
	@echo ""
	@echo "Variables : PROFILE=$(PROFILE) (minimal|dev), YES=1 (non interactif),"
	@echo "            GIT_NAME=..., GIT_EMAIL=..."

dry-run: ## Aperçu sans modification (onboard.sh --dry-run)
	$(SCRIPT) --dry-run $(COMMON_ARGS)

run: ## Exécution réelle de l'onboarding (peut demander sudo)
	$(SCRIPT) $(COMMON_ARGS)

lint: ## Analyse statique des scripts shell avec shellcheck
	@command -v shellcheck >/dev/null 2>&1 || { \
		echo "shellcheck introuvable. Installez-le (apt/dnf/pacman/zypper install shellcheck)." >&2; \
		exit 1; \
	}
	shellcheck --shell=bash --external-sources $(SHELL_FILES)
	@echo "shellcheck : aucun problème détecté."
