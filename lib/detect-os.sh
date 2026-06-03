#!/usr/bin/env bash
# lib/detect-os.sh — Détection de la distribution Linux et du gestionnaire de
# paquets associé.
#
# Ce module est destiné à être sourcé par onboard.sh. Il s'appuie sur
# lib/log.sh, qui doit donc être chargé au préalable.
#
# Après appel de detect_os(), les variables globales suivantes sont
# renseignées :
#   OS_ID        — identifiant de la distro (ex. ubuntu, debian, fedora,
#                  rhel, centos, arch, opensuse-leap, ...). Issu de
#                  /etc/os-release (champ ID).
#   OS_ID_LIKE   — familles parentes déclarées (ex. "debian", "rhel fedora").
#   OS_NAME      — nom lisible (champ PRETTY_NAME ou NAME).
#   OS_VERSION   — version (champ VERSION_ID), éventuellement vide.
#   PKG_MANAGER  — gestionnaire détecté : apt | dnf | yum | pacman | zypper.
#
# Matrice de correspondance distro -> gestionnaire (cf. README) :
#   apt     : debian, ubuntu, linuxmint, pop, raspbian, kali, elementary
#   dnf/yum : fedora, rhel, centos, rocky, almalinux, ol (Oracle Linux)
#   pacman  : arch, manjaro, endeavouros, garuda
#   zypper  : opensuse-*, sles
#
# La détection combine deux stratégies, par ordre de priorité :
#   1. /etc/os-release (norme freedesktop, présente sur toute distro moderne) ;
#   2. présence des binaires de gestionnaires dans le PATH (repli robuste).

if [[ -n "${__ONBOARD_DETECT_OS_SH_LOADED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
__ONBOARD_DETECT_OS_SH_LOADED=1

OS_ID=""
OS_ID_LIKE=""
OS_NAME=""
OS_VERSION=""
PKG_MANAGER=""

# Lit /etc/os-release (ou /usr/lib/os-release en repli) et renseigne
# OS_ID / OS_ID_LIKE / OS_NAME / OS_VERSION. Renvoie 1 si aucun fichier.
__detect_read_os_release() {
  local file=""
  if [[ -r /etc/os-release ]]; then
    file="/etc/os-release"
  elif [[ -r /usr/lib/os-release ]]; then
    file="/usr/lib/os-release"
  else
    return 1
  fi

  # On lit le fichier dans un sous-shell pour éviter d'exporter ses variables
  # brutes (ID, NAME, ...) dans l'environnement courant, puis on récupère les
  # champs voulus via un format contrôlé.
  local id id_like pretty name version
  # shellcheck disable=SC1090
  id="$(. "${file}" >/dev/null 2>&1; printf '%s' "${ID:-}")"
  # shellcheck disable=SC1090
  id_like="$(. "${file}" >/dev/null 2>&1; printf '%s' "${ID_LIKE:-}")"
  # shellcheck disable=SC1090
  pretty="$(. "${file}" >/dev/null 2>&1; printf '%s' "${PRETTY_NAME:-}")"
  # shellcheck disable=SC1090
  name="$(. "${file}" >/dev/null 2>&1; printf '%s' "${NAME:-}")"
  # shellcheck disable=SC1090
  version="$(. "${file}" >/dev/null 2>&1; printf '%s' "${VERSION_ID:-}")"

  OS_ID="${id}"
  OS_ID_LIKE="${id_like}"
  OS_NAME="${pretty:-${name}}"
  OS_VERSION="${version}"
  return 0
}

# Déduit PKG_MANAGER à partir de OS_ID puis de OS_ID_LIKE.
# Renvoie 0 si un gestionnaire a pu être déterminé, 1 sinon.
__detect_pkg_from_id() {
  local token
  # On teste d'abord l'identifiant exact, puis chaque famille parente.
  for token in "${OS_ID}" ${OS_ID_LIKE}; do
    case "${token}" in
      debian|ubuntu|linuxmint|pop|raspbian|kali|elementary|devuan)
        PKG_MANAGER="apt"; return 0 ;;
      fedora|rhel|centos|rocky|almalinux|ol|amzn)
        # dnf est le standard moderne ; yum sert de repli (cf. détection binaire).
        PKG_MANAGER="dnf"; return 0 ;;
      arch|manjaro|endeavouros|garuda|artix)
        PKG_MANAGER="pacman"; return 0 ;;
      opensuse|opensuse-leap|opensuse-tumbleweed|sles|sled|suse)
        PKG_MANAGER="zypper"; return 0 ;;
    esac
  done
  return 1
}

# Repli : déduit PKG_MANAGER selon les binaires présents dans le PATH.
# L'ordre reflète les familles les plus répandues.
__detect_pkg_from_binaries() {
  local mgr
  for mgr in apt-get apt dnf yum pacman zypper; do
    if command -v "${mgr}" >/dev/null 2>&1; then
      case "${mgr}" in
        apt-get|apt) PKG_MANAGER="apt" ;;
        dnf)         PKG_MANAGER="dnf" ;;
        yum)         PKG_MANAGER="yum" ;;
        pacman)      PKG_MANAGER="pacman" ;;
        zypper)      PKG_MANAGER="zypper" ;;
      esac
      return 0
    fi
  done
  return 1
}

# detect_os — point d'entrée public.
# Renseigne les variables globales et journalise le résultat.
# Quitte le script (code 3) si la plateforme n'est pas un Linux pris en charge.
detect_os() {
  local uname_s
  uname_s="$(uname -s 2>/dev/null || echo unknown)"
  if [[ "${uname_s}" != "Linux" ]]; then
    log_die 3 "Plateforme non prise en charge : '${uname_s}'. Ce script cible Linux uniquement."
  fi

  if ! __detect_read_os_release; then
    log_warn "/etc/os-release introuvable : repli sur la détection par binaires."
  fi

  # Si dnf annoncé mais absent alors que yum est présent, on bascule sur yum
  # (cas des RHEL/CentOS 7 anciens).
  if ! __detect_pkg_from_id; then
    log_debug "Gestionnaire non déduit de os-release ; tentative via les binaires."
    if ! __detect_pkg_from_binaries; then
      log_die 3 "Aucun gestionnaire de paquets pris en charge (apt/dnf/yum/pacman/zypper) n'a été trouvé."
    fi
  fi

  # Ajustement dnf -> yum si dnf n'existe pas réellement sur la machine.
  if [[ "${PKG_MANAGER}" == "dnf" ]] && ! command -v dnf >/dev/null 2>&1; then
    if command -v yum >/dev/null 2>&1; then
      log_debug "dnf indisponible : utilisation de yum à la place."
      PKG_MANAGER="yum"
    fi
  fi

  # Valeurs de repli pour l'affichage si os-release était absent.
  : "${OS_ID:=inconnu}"
  : "${OS_NAME:=Linux (${OS_ID})}"

  log_info "Distribution détectée : ${OS_NAME} (id=${OS_ID}, version=${OS_VERSION:-n/a})"
  log_info "Gestionnaire de paquets : ${PKG_MANAGER}"
}
