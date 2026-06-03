#!/usr/bin/env bash
# lib/log.sh — Fonctions de journalisation horodatées et colorées.
#
# Ce module est destiné à être sourcé par onboard.sh (et les autres
# bibliothèques). Il n'a pas vocation à être exécuté directement.
#
# Variables d'environnement reconnues :
#   NO_COLOR   — si définie (valeur quelconque), désactive toute couleur.
#   LOG_LEVEL  — niveau minimal affiché : DEBUG < INFO < WARN < ERROR.
#                Valeur par défaut : INFO.
#
# Toutes les fonctions écrivent sur la sortie d'erreur (stderr) afin de ne
# pas polluer la sortie standard, qui peut être capturée par un appelant.

# Garde anti-double-inclusion : si le module est déjà chargé, on ne refait rien.
if [[ -n "${__ONBOARD_LOG_SH_LOADED:-}" ]]; then
  return 0 2>/dev/null || exit 0
fi
__ONBOARD_LOG_SH_LOADED=1

# ---------------------------------------------------------------------------
# Détection de la prise en charge des couleurs.
# On active les couleurs uniquement si :
#   - la variable NO_COLOR n'est pas définie ;
#   - stderr est rattaché à un terminal interactif (-t 2) ;
#   - le terminal annonce au moins 8 couleurs via tput (si tput est dispo).
# ---------------------------------------------------------------------------
__log_init_colors() {
  __LOG_C_RESET=""
  __LOG_C_DEBUG=""
  __LOG_C_INFO=""
  __LOG_C_WARN=""
  __LOG_C_ERROR=""
  __LOG_C_BOLD=""

  if [[ -n "${NO_COLOR:-}" ]]; then
    return 0
  fi
  if [[ ! -t 2 ]]; then
    return 0
  fi

  local colors=8
  if command -v tput >/dev/null 2>&1; then
    # tput peut échouer si TERM est inconnu : on protège l'appel.
    colors="$(tput colors 2>/dev/null || echo 0)"
  fi
  if [[ "${colors}" -lt 8 ]]; then
    return 0
  fi

  __LOG_C_RESET=$'\033[0m'
  __LOG_C_DEBUG=$'\033[2;37m'   # gris
  __LOG_C_INFO=$'\033[0;36m'    # cyan
  __LOG_C_WARN=$'\033[0;33m'    # jaune
  __LOG_C_ERROR=$'\033[0;31m'   # rouge
  __LOG_C_BOLD=$'\033[1m'
}
__log_init_colors

# Conversion d'un niveau textuel en valeur numérique pour comparaison.
__log_level_value() {
  case "${1:-INFO}" in
    DEBUG) echo 10 ;;
    INFO)  echo 20 ;;
    WARN)  echo 30 ;;
    ERROR) echo 40 ;;
    *)     echo 20 ;;
  esac
}

# Renvoie un horodatage ISO-8601 local (ex. 2026-06-03T14:09:55+0200).
__log_timestamp() {
  date +"%Y-%m-%dT%H:%M:%S%z"
}

# Fonction interne générique : __log <NIVEAU> <COULEUR> <message...>
__log() {
  local level="$1"; shift
  local color="$1"; shift

  local threshold current
  threshold="$(__log_level_value "${LOG_LEVEL:-INFO}")"
  current="$(__log_level_value "${level}")"
  if [[ "${current}" -lt "${threshold}" ]]; then
    return 0
  fi

  printf '%s%s [%s]%s %s\n' \
    "${color}" "$(__log_timestamp)" "${level}" "${__LOG_C_RESET}" "$*" >&2
}

# Niveau DEBUG — détails utiles au diagnostic, masqués par défaut.
log_debug() { __log "DEBUG" "${__LOG_C_DEBUG}" "$@"; }

# Niveau INFO — déroulé normal du script.
log_info()  { __log "INFO"  "${__LOG_C_INFO}"  "$@"; }

# Niveau WARN — situation anormale non bloquante.
log_warn()  { __log "WARN"  "${__LOG_C_WARN}"  "$@"; }

# Niveau ERROR — échec ; n'interrompt pas le script par lui-même.
log_error() { __log "ERROR" "${__LOG_C_ERROR}" "$@"; }

# log_die <code> <message...> — journalise une erreur puis quitte le script.
log_die() {
  local code="$1"; shift
  log_error "$@"
  exit "${code}"
}

# log_section <titre> — affiche un séparateur visuel pour structurer la sortie.
log_section() {
  printf '\n%s==> %s%s\n' "${__LOG_C_BOLD}" "$*" "${__LOG_C_RESET}" >&2
}
