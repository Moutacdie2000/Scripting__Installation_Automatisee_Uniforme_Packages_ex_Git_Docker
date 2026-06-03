#!/usr/bin/env bash
# lib/packages.sh — Abstraction au-dessus des gestionnaires de paquets.
#
# Ce module fournit une interface unique (rafraîchir l'index, installer une
# liste de paquets) quel que soit le gestionnaire détecté par detect-os.sh.
#
# Dépendances : lib/log.sh et lib/detect-os.sh doivent être chargés avant.
# Variables globales attendues : PKG_MANAGER, OS_ID, OS_ID_LIKE.
#
# Variables de comportement (positionnées par onboard.sh) :
#   DRY_RUN          — "1" pour n'afficher les commandes sans les exécuter.
#   ASSUME_YES       — "1" pour répondre oui automatiquement (mode non interactif).
#   SUDO             — préfixe de privilèges ("sudo" ou "" si déjà root).
#
# Remarque : certains paquets portent des noms différents selon les distros
# (ex. ca-certificates est commun, mais Docker n'est pas un simple paquet).
# La fonction map_package_name() centralise ces correspondances et
# install_docker() traite le cas particulier de Docker.

if [[ -n "${__ONBOARD_PACKAGES_SH_LOADED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
__ONBOARD_PACKAGES_SH_LOADED=1

# ---------------------------------------------------------------------------
# run_cmd <commande...>
# Exécute une commande en respectant le mode --dry-run.
# En dry-run, la commande est seulement affichée (préfixe « [dry-run] »).
# Renvoie le code de sortie réel de la commande (0 en dry-run).
# ---------------------------------------------------------------------------
run_cmd() {
  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    log_info "[dry-run] $*"
    return 0
  fi
  log_debug "exécution : $*"
  "$@"
}

# ---------------------------------------------------------------------------
# map_package_name <gestionnaire> <nom_générique>
# Traduit un nom de paquet « générique » (tel qu'écrit dans packages.conf)
# vers le nom réel attendu par le gestionnaire cible. Renvoie le nom mappé
# sur stdout. Si aucune correspondance n'est connue, renvoie le nom d'entrée.
# Le pseudo-paquet « docker » est volontairement renvoyé tel quel : il est
# traité séparément par install_docker().
# ---------------------------------------------------------------------------
map_package_name() {
  local mgr="$1"
  local pkg="$2"

  case "${pkg}" in
    ca-certificates)
      # Même nom sur apt/dnf/zypper. Sur Arch, le paquet est « ca-certificates »
      # également (méta-paquet), donc pas de changement.
      printf '%s' "ca-certificates"
      ;;
    htop|jq|wget|curl|git|vim|unzip)
      # Ces noms sont identiques sur l'ensemble des gestionnaires visés.
      printf '%s' "${pkg}"
      ;;
    docker)
      # Cas spécial, géré par install_docker(). On renvoie le nom inchangé.
      printf '%s' "docker"
      ;;
    *)
      # Par défaut, on suppose un nom commun à toutes les distros.
      printf '%s' "${pkg}"
      ;;
  esac
  # Le paramètre mgr est conservé pour d'éventuelles divergences futures.
  : "${mgr}"
}

# ---------------------------------------------------------------------------
# pkg_is_installed <gestionnaire> <paquet_réel>
# Renvoie 0 si le paquet est déjà installé, 1 sinon. Sert à l'idempotence et
# à des journaux informatifs (on n'empêche pas le gestionnaire de re-traiter
# un paquet, mais on évite des messages trompeurs).
# ---------------------------------------------------------------------------
pkg_is_installed() {
  local mgr="$1"
  local pkg="$2"
  case "${mgr}" in
    apt)
      dpkg-query -W -f='${Status}' "${pkg}" 2>/dev/null | grep -q "install ok installed"
      ;;
    dnf|yum)
      rpm -q "${pkg}" >/dev/null 2>&1
      ;;
    pacman)
      pacman -Qi "${pkg}" >/dev/null 2>&1
      ;;
    zypper)
      rpm -q "${pkg}" >/dev/null 2>&1
      ;;
    *)
      return 1
      ;;
  esac
}

# ---------------------------------------------------------------------------
# pkg_refresh
# Rafraîchit l'index des paquets du gestionnaire courant. Idempotent.
# ---------------------------------------------------------------------------
pkg_refresh() {
  log_section "Rafraîchissement de l'index des paquets (${PKG_MANAGER})"
  case "${PKG_MANAGER}" in
    apt)
      run_cmd ${SUDO} apt-get update
      ;;
    dnf)
      # makecache est idempotent et accélère les installations suivantes.
      run_cmd ${SUDO} dnf -y makecache
      ;;
    yum)
      run_cmd ${SUDO} yum -y makecache
      ;;
    pacman)
      # -Sy synchronise la base ; on évite -Syu ici pour ne pas forcer une
      # mise à niveau complète non sollicitée du système.
      run_cmd ${SUDO} pacman -Sy --noconfirm
      ;;
    zypper)
      run_cmd ${SUDO} zypper --non-interactive refresh
      ;;
    *)
      log_die 4 "Gestionnaire inconnu pour le rafraîchissement : '${PKG_MANAGER}'."
      ;;
  esac
}

# ---------------------------------------------------------------------------
# pkg_install <paquet_réel...>
# Installe un ou plusieurs paquets avec le gestionnaire courant, en mode non
# interactif si ASSUME_YES=1. Idempotent (les paquets déjà présents sont
# simplement ignorés par le gestionnaire).
# ---------------------------------------------------------------------------
pkg_install() {
  if [[ "$#" -eq 0 ]]; then
    log_warn "pkg_install appelée sans argument : rien à installer."
    return 0
  fi

  local yes_flag=""
  case "${PKG_MANAGER}" in
    apt)
      [[ "${ASSUME_YES:-0}" == "1" ]] && yes_flag="-y"
      # DEBIAN_FRONTEND évite les invites de configuration interactives.
      run_cmd ${SUDO} env DEBIAN_FRONTEND=noninteractive \
        apt-get install ${yes_flag} --no-install-recommends "$@"
      ;;
    dnf)
      [[ "${ASSUME_YES:-0}" == "1" ]] && yes_flag="-y"
      run_cmd ${SUDO} dnf install ${yes_flag} "$@"
      ;;
    yum)
      [[ "${ASSUME_YES:-0}" == "1" ]] && yes_flag="-y"
      run_cmd ${SUDO} yum install ${yes_flag} "$@"
      ;;
    pacman)
      # --needed rend l'opération idempotente (ne réinstalle pas l'existant).
      if [[ "${ASSUME_YES:-0}" == "1" ]]; then
        run_cmd ${SUDO} pacman -S --needed --noconfirm "$@"
      else
        run_cmd ${SUDO} pacman -S --needed "$@"
      fi
      ;;
    zypper)
      if [[ "${ASSUME_YES:-0}" == "1" ]]; then
        run_cmd ${SUDO} zypper --non-interactive install "$@"
      else
        run_cmd ${SUDO} zypper install "$@"
      fi
      ;;
    *)
      log_die 4 "Gestionnaire inconnu pour l'installation : '${PKG_MANAGER}'."
      ;;
  esac
}

# ---------------------------------------------------------------------------
# install_tools <paquet_générique...>
# Traduit chaque nom générique, sépare le cas Docker, et installe le reste en
# un seul appel au gestionnaire (plus rapide et plus sûr pour la résolution
# de dépendances).
# ---------------------------------------------------------------------------
install_tools() {
  local generic mapped
  local -a to_install=()
  local want_docker=0

  for generic in "$@"; do
    if [[ "${generic}" == "docker" ]]; then
      want_docker=1
      continue
    fi
    mapped="$(map_package_name "${PKG_MANAGER}" "${generic}")"
    if pkg_is_installed "${PKG_MANAGER}" "${mapped}"; then
      log_info "Déjà installé : ${mapped} (${generic})"
    else
      to_install+=("${mapped}")
    fi
  done

  if [[ "${#to_install[@]}" -gt 0 ]]; then
    log_section "Installation des outils : ${to_install[*]}"
    pkg_install "${to_install[@]}"
  else
    log_info "Aucun outil de base à installer (tous déjà présents)."
  fi

  if [[ "${want_docker}" -eq 1 ]]; then
    install_docker
  fi
}

# ---------------------------------------------------------------------------
# install_docker
# Installe le moteur Docker selon la distribution. On privilégie le paquet
# fourni par les dépôts officiels de la distro (docker.io sur Debian/Ubuntu,
# docker sur Fedora/Arch/openSUSE), ce qui suffit largement à une machine
# d'onboarding et évite l'ajout d'un dépôt tiers.
# ---------------------------------------------------------------------------
install_docker() {
  log_section "Installation de Docker"

  if command -v docker >/dev/null 2>&1; then
    log_info "Docker est déjà présent : $(docker --version 2>/dev/null || echo 'version inconnue')."
  else
    case "${PKG_MANAGER}" in
      apt)
        # docker.io = paquet Docker des dépôts Debian/Ubuntu.
        pkg_install docker.io
        ;;
      dnf|yum)
        # « docker » pointe vers Moby/docker sur Fedora ; podman-docker est une
        # alternative gérée hors de ce script.
        pkg_install docker
        ;;
      pacman)
        pkg_install docker
        ;;
      zypper)
        pkg_install docker
        ;;
      *)
        log_warn "Installation de Docker non prise en charge pour '${PKG_MANAGER}' : étape ignorée."
        return 0
        ;;
    esac
  fi

  # Activation du service au démarrage si systemd est présent.
  if command -v systemctl >/dev/null 2>&1; then
    log_info "Activation et démarrage du service docker (systemd)."
    run_cmd ${SUDO} systemctl enable --now docker || \
      log_warn "Impossible d'activer/démarrer le service docker (à vérifier manuellement)."
  else
    log_warn "systemctl introuvable : activez le service Docker selon votre init système."
  fi
}
