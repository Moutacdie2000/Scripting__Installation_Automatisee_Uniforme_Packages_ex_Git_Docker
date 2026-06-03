#!/usr/bin/env bash
#
# onboard.sh — Script d'onboarding pour nouvelles machines Linux.
#
# Détecte la distribution et le gestionnaire de paquets (apt/dnf/pacman/
# zypper/yum), installe une liste d'outils de base selon un profil, configure
# l'identité Git (nom/email) et ajoute l'utilisateur courant au groupe docker.
#
# Auteur  : Noumabeu Moutacdie Jordan
# Licence : MIT (voir LICENSE)
#
# Usage rapide :
#   ./onboard.sh --help
#   sudo ./onboard.sh --profile dev --yes \
#        --git-name "Jane Doe" --git-email "jane@example.com"
#   ./onboard.sh --dry-run --profile minimal
#
set -euo pipefail

# ---------------------------------------------------------------------------
# Résolution du répertoire du script (pour sourcer lib/ de façon robuste,
# quel que soit le répertoire courant ou un éventuel lien symbolique).
# ---------------------------------------------------------------------------
__resolve_script_dir() {
  local src="${BASH_SOURCE[0]}"
  local dir
  while [[ -h "${src}" ]]; do
    dir="$(cd -P "$(dirname "${src}")" >/dev/null 2>&1 && pwd)"
    src="$(readlink "${src}")"
    [[ "${src}" != /* ]] && src="${dir}/${src}"
  done
  cd -P "$(dirname "${src}")" >/dev/null 2>&1 && pwd
}
SCRIPT_DIR="$(__resolve_script_dir)"
LIB_DIR="${SCRIPT_DIR}/lib"
CONFIG_FILE="${SCRIPT_DIR}/packages.conf"

# ---------------------------------------------------------------------------
# Chargement des bibliothèques sourcées (ordre important : log -> detect -> packages).
# ---------------------------------------------------------------------------
# shellcheck source=lib/log.sh
. "${LIB_DIR}/log.sh"
# shellcheck source=lib/detect-os.sh
. "${LIB_DIR}/detect-os.sh"
# shellcheck source=lib/packages.sh
. "${LIB_DIR}/packages.sh"

# ---------------------------------------------------------------------------
# Valeurs par défaut des options (surchargées par la ligne de commande).
# ---------------------------------------------------------------------------
DRY_RUN=0
ASSUME_YES=0
PROFILE=""            # vide -> on prendra DEFAULT_PROFILE de packages.conf
GIT_NAME=""
GIT_EMAIL=""
SKIP_DOCKER_GROUP=0
SUDO=""               # déterminé plus bas selon l'UID

# ---------------------------------------------------------------------------
# usage — affiche l'aide détaillée puis renvoie 0.
# ---------------------------------------------------------------------------
usage() {
  cat <<'EOF'
onboard.sh — Onboarding de machines Linux (paquets + configuration de base)

USAGE :
    onboard.sh [OPTIONS]

OPTIONS :
    -p, --profile <minimal|dev>   Profil d'outils à installer.
                                  Par défaut : valeur DEFAULT_PROFILE de
                                  packages.conf.
    -y, --yes                     Mode non interactif : répond « oui » à toutes
                                  les invites du gestionnaire de paquets.
    -n, --dry-run                 N'exécute rien : affiche les commandes qui
                                  seraient lancées. Implique l'absence de
                                  modification du système.
        --git-name <nom>          Nom à configurer pour Git (user.name, global).
        --git-email <email>       Email à configurer pour Git (user.email, global).
        --skip-docker-group       N'ajoute pas l'utilisateur au groupe docker.
    -h, --help                    Affiche cette aide et quitte.

EXEMPLES :
    # Aperçu sans rien modifier (recommandé pour une première exécution) :
    onboard.sh --dry-run --profile dev

    # Installation complète, non interactive, avec configuration Git :
    sudo onboard.sh -y -p dev \
        --git-name "Jane Doe" --git-email "jane@example.com"

    # Profil minimal uniquement :
    sudo onboard.sh --yes --profile minimal

VARIABLES D'ENVIRONNEMENT :
    NO_COLOR     Désactive la couleur des journaux si définie.
    LOG_LEVEL    Niveau de journalisation : DEBUG|INFO|WARN|ERROR (def. INFO).

CODES DE SORTIE :
    0  succès
    1  erreur d'argument / usage
    2  prérequis manquant (ex. fichier de configuration absent)
    3  plateforme ou distribution non prise en charge
    4  échec lié au gestionnaire de paquets
EOF
  return 0
}

# ---------------------------------------------------------------------------
# parse_args — analyse les arguments de la ligne de commande.
# ---------------------------------------------------------------------------
parse_args() {
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      -p|--profile)
        [[ "$#" -ge 2 ]] || log_die 1 "L'option '$1' attend une valeur (minimal|dev)."
        PROFILE="$2"; shift 2 ;;
      --profile=*)
        PROFILE="${1#*=}"; shift ;;
      -y|--yes)
        ASSUME_YES=1; shift ;;
      -n|--dry-run)
        DRY_RUN=1; shift ;;
      --git-name)
        [[ "$#" -ge 2 ]] || log_die 1 "L'option '$1' attend une valeur."
        GIT_NAME="$2"; shift 2 ;;
      --git-name=*)
        GIT_NAME="${1#*=}"; shift ;;
      --git-email)
        [[ "$#" -ge 2 ]] || log_die 1 "L'option '$1' attend une valeur."
        GIT_EMAIL="$2"; shift 2 ;;
      --git-email=*)
        GIT_EMAIL="${1#*=}"; shift ;;
      --skip-docker-group)
        SKIP_DOCKER_GROUP=1; shift ;;
      -h|--help)
        usage; exit 0 ;;
      --)
        shift; break ;;
      -*)
        log_die 1 "Option inconnue : '$1'. Utilisez --help pour l'aide." ;;
      *)
        log_die 1 "Argument positionnel inattendu : '$1'. Utilisez --help." ;;
    esac
  done

  # Validation du profil si fourni explicitement.
  if [[ -n "${PROFILE}" && "${PROFILE}" != "minimal" && "${PROFILE}" != "dev" ]]; then
    log_die 1 "Profil invalide : '${PROFILE}'. Valeurs acceptées : minimal, dev."
  fi
}

# ---------------------------------------------------------------------------
# load_config — charge packages.conf et résout le profil effectif.
# Renseigne la variable SELECTED_PACKAGES (tableau) et PROFILE.
# ---------------------------------------------------------------------------
SELECTED_PACKAGES=()
load_config() {
  [[ -r "${CONFIG_FILE}" ]] || log_die 2 "Fichier de configuration introuvable ou illisible : ${CONFIG_FILE}"

  # shellcheck source=packages.conf
  . "${CONFIG_FILE}"

  # Profil par défaut issu du fichier si non précisé en ligne de commande.
  if [[ -z "${PROFILE}" ]]; then
    PROFILE="${DEFAULT_PROFILE:-minimal}"
    log_debug "Profil non précisé : utilisation de DEFAULT_PROFILE='${PROFILE}'."
  fi

  case "${PROFILE}" in
    minimal)
      [[ -n "${PACKAGES_MINIMAL+x}" ]] || log_die 2 "Tableau PACKAGES_MINIMAL absent de ${CONFIG_FILE}."
      SELECTED_PACKAGES=("${PACKAGES_MINIMAL[@]}") ;;
    dev)
      [[ -n "${PACKAGES_DEV+x}" ]] || log_die 2 "Tableau PACKAGES_DEV absent de ${CONFIG_FILE}."
      SELECTED_PACKAGES=("${PACKAGES_DEV[@]}") ;;
    *)
      log_die 1 "Profil invalide après chargement : '${PROFILE}'." ;;
  esac

  log_info "Profil sélectionné : ${PROFILE} (${#SELECTED_PACKAGES[@]} paquets)."
  log_debug "Paquets : ${SELECTED_PACKAGES[*]}"
}

# ---------------------------------------------------------------------------
# setup_privileges — détermine s'il faut préfixer les commandes par sudo.
# - root  : SUDO reste vide.
# - non-root + sudo dispo : SUDO="sudo".
# - non-root sans sudo : erreur (sauf en dry-run, où l'on tolère pour l'aperçu).
# ---------------------------------------------------------------------------
setup_privileges() {
  if [[ "${EUID:-$(id -u)}" -eq 0 ]]; then
    SUDO=""
    log_debug "Exécution en tant que root : sudo non nécessaire."
    return 0
  fi

  if command -v sudo >/dev/null 2>&1; then
    SUDO="sudo"
    log_info "Exécution non privilégiée : les commandes système utiliseront sudo."
  else
    if [[ "${DRY_RUN}" -eq 1 ]]; then
      SUDO="sudo"
      log_warn "sudo introuvable, mais --dry-run actif : les commandes affichées supposeront sudo."
    else
      log_die 2 "Exécution non privilégiée et 'sudo' introuvable. Relancez en root ou installez sudo."
    fi
  fi
}

# ---------------------------------------------------------------------------
# configure_git — positionne user.name / user.email en global si fournis.
# Idempotent : réécrit simplement les valeurs. Ignoré si Git absent.
# ---------------------------------------------------------------------------
configure_git() {
  if [[ -z "${GIT_NAME}" && -z "${GIT_EMAIL}" ]]; then
    log_debug "Aucune valeur Git fournie : configuration Git ignorée."
    return 0
  fi

  if ! command -v git >/dev/null 2>&1 && [[ "${DRY_RUN}" -ne 1 ]]; then
    log_warn "git introuvable : configuration Git ignorée (le paquet vient peut-être d'être listé en dry-run)."
    return 0
  fi

  log_section "Configuration de Git"

  if [[ -n "${GIT_NAME}" ]]; then
    log_info "git config --global user.name = '${GIT_NAME}'"
    run_cmd git config --global user.name "${GIT_NAME}"
  fi
  if [[ -n "${GIT_EMAIL}" ]]; then
    log_info "git config --global user.email = '${GIT_EMAIL}'"
    run_cmd git config --global user.email "${GIT_EMAIL}"
  fi
}

# ---------------------------------------------------------------------------
# configure_docker_group — ajoute l'utilisateur courant au groupe docker afin
# d'utiliser Docker sans sudo. Idempotent (ne réajoute pas si déjà membre).
# N'est exécuté que si Docker fait partie des paquets sélectionnés.
# ---------------------------------------------------------------------------
configure_docker_group() {
  if [[ "${SKIP_DOCKER_GROUP}" -eq 1 ]]; then
    log_debug "--skip-docker-group : ajout au groupe docker ignoré."
    return 0
  fi

  # On ne configure le groupe que si docker est dans la sélection.
  local has_docker=0 pkg
  for pkg in "${SELECTED_PACKAGES[@]}"; do
    if [[ "${pkg}" == "docker" ]]; then
      has_docker=1
      break
    fi
  done
  if [[ "${has_docker}" -eq 0 ]]; then
    log_debug "Docker absent du profil : pas de configuration du groupe docker."
    return 0
  fi

  log_section "Ajout de l'utilisateur au groupe docker"

  # Détermination de l'utilisateur cible : si root via sudo, on vise l'appelant
  # réel (SUDO_USER) pour ne pas configurer « root ».
  local target_user="${SUDO_USER:-${USER:-$(id -un)}}"
  if [[ "${target_user}" == "root" ]]; then
    log_warn "Utilisateur cible = root : l'ajout au groupe docker n'a pas de sens, étape ignorée."
    return 0
  fi

  # Idempotence : si déjà membre, on ne fait rien.
  if id -nG "${target_user}" 2>/dev/null | tr ' ' '\n' | grep -qx "docker"; then
    log_info "L'utilisateur '${target_user}' est déjà membre du groupe docker."
    return 0
  fi

  # Création du groupe docker s'il n'existe pas (cas rare si Docker pas encore prêt).
  if ! getent group docker >/dev/null 2>&1; then
    log_info "Création du groupe 'docker'."
    run_cmd ${SUDO} groupadd docker || log_warn "Échec de la création du groupe docker (peut-être déjà créé)."
  fi

  log_info "Ajout de '${target_user}' au groupe docker."
  run_cmd ${SUDO} usermod -aG docker "${target_user}"
  log_warn "Déconnectez/reconnectez la session de '${target_user}' (ou exécutez 'newgrp docker') pour activer l'appartenance au groupe."
}

# ---------------------------------------------------------------------------
# print_summary — récapitulatif lisible avant exécution des étapes système.
# ---------------------------------------------------------------------------
print_summary() {
  log_section "Récapitulatif de l'onboarding"
  log_info "Distribution    : ${OS_NAME} (${OS_ID})"
  log_info "Gestionnaire    : ${PKG_MANAGER}"
  log_info "Profil          : ${PROFILE}"
  log_info "Paquets         : ${SELECTED_PACKAGES[*]}"
  log_info "Mode dry-run    : $([[ "${DRY_RUN}" -eq 1 ]] && echo oui || echo non)"
  log_info "Mode non interactif (--yes) : $([[ "${ASSUME_YES}" -eq 1 ]] && echo oui || echo non)"
  log_info "Git name        : ${GIT_NAME:-<non défini>}"
  log_info "Git email       : ${GIT_EMAIL:-<non défini>}"
  log_info "Groupe docker   : $([[ "${SKIP_DOCKER_GROUP}" -eq 1 ]] && echo 'ignoré' || echo 'configuré si Docker présent')"
}

# ---------------------------------------------------------------------------
# main — orchestration globale.
# ---------------------------------------------------------------------------
main() {
  parse_args "$@"

  log_section "onboard.sh — démarrage"
  detect_os
  load_config
  setup_privileges
  print_summary

  pkg_refresh
  install_tools "${SELECTED_PACKAGES[@]}"

  configure_git
  configure_docker_group

  log_section "Onboarding terminé"
  if [[ "${DRY_RUN}" -eq 1 ]]; then
    log_info "Mode --dry-run : aucune modification réelle n'a été appliquée."
  else
    log_info "Toutes les étapes se sont déroulées avec succès."
  fi
}

main "$@"
