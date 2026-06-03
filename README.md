# scripting-onboarding, Onboarding automatisé de machines Linux

Script Bash d'**onboarding** qui prépare une nouvelle machine Linux en quelques
secondes : il détecte la distribution et son gestionnaire de paquets, installe
une liste d'outils de base selon un profil, configure l'identité Git et ajoute
l'utilisateur courant au groupe `docker`.

L'objectif est de remplacer la suite de commandes manuelles que l'on tape sur
chaque nouveau poste ou serveur par **une seule commande reproductible**,
fonctionnant indifféremment sur Debian/Ubuntu, Fedora/RHEL, Arch ou openSUSE.

---

## Sommaire

- [Objectif](#objectif)
- [Ce que le script fait](#ce-que-le-script-fait)
- [Matrice distribution → gestionnaire de paquets](#matrice-distribution--gestionnaire-de-paquets)
- [Prérequis](#prérequis)
- [Structure du projet](#structure-du-projet)
- [Installation](#installation)
- [Usage](#usage)
  - [Options](#options)
  - [Exemples concrets](#exemples-concrets)
  - [Via le Makefile](#via-le-makefile)
- [Personnalisation (`packages.conf`)](#personnalisation-packagesconf)
- [Idempotence et sécurité](#idempotence-et-sécurité)
- [Ce que ce projet démontre](#ce-que-ce-projet-démontre)
- [Licence](#licence)

---

## Objectif

Lorsqu'on reçoit une nouvelle machine Linux (poste de travail, VM, serveur),
on répète toujours les mêmes gestes : mettre à jour l'index des paquets,
installer `git`, `curl`, `docker`, configurer son nom/email Git, se donner le
droit d'utiliser Docker sans `sudo`, etc.

`onboard.sh` **automatise et standardise** ces gestes, tout en restant :

- **portable** : une même commande pour `apt`, `dnf`, `pacman`, `zypper`, `yum` ;
- **sûr** : un mode `--dry-run` permet de tout prévisualiser sans rien modifier ;
- **idempotent** : on peut le relancer sans effet de bord (rien n'est cassé si
  les outils sont déjà installés).

---

## Ce que le script fait

1. **Détecte la distribution** via `/etc/os-release` (avec repli sur les
   binaires présents) et en déduit le **gestionnaire de paquets**.
2. **Rafraîchit l'index** des paquets du gestionnaire.
3. **Installe les outils** du profil choisi. Profils fournis :
   - `minimal` : `ca-certificates`, `curl`, `wget`, `git`, `vim`, `unzip` ;
   - `dev` (défaut) : le profil `minimal` **+** `htop`, `jq` et **Docker**.
4. **Configure Git** (`user.name` / `user.email` en global) si fournis.
5. **Ajoute l'utilisateur au groupe `docker`** (sauf `--skip-docker-group`),
   pour utiliser Docker sans `sudo`.

L'ensemble des listes d'outils est centralisé dans le fichier **éditable**
[`packages.conf`](packages.conf).

---

## Matrice distribution → gestionnaire de paquets

Le script reconnaît la distribution puis sélectionne le gestionnaire adéquat.
La détection s'appuie d'abord sur le champ `ID`, puis sur `ID_LIKE`, de
`/etc/os-release`, et enfin sur les binaires disponibles.

| Gestionnaire | Distributions reconnues (`ID` / `ID_LIKE`)                                  | Commande d'installation sous-jacente            |
|--------------|------------------------------------------------------------------------------|-------------------------------------------------|
| **apt**      | Debian, Ubuntu, Linux Mint, Pop!_OS, Raspberry Pi OS, Kali, elementary, Devuan | `apt-get install --no-install-recommends`       |
| **dnf**      | Fedora, RHEL 8+, CentOS Stream, Rocky Linux, AlmaLinux, Oracle Linux, Amazon Linux | `dnf install`                              |
| **yum**      | RHEL/CentOS 7 (repli automatique si `dnf` est absent)                        | `yum install`                                   |
| **pacman**   | Arch Linux, Manjaro, EndeavourOS, Garuda, Artix                              | `pacman -S --needed`                            |
| **zypper**   | openSUSE Leap, openSUSE Tumbleweed, SLES, SLED                               | `zypper --non-interactive install`              |

> Le moteur **Docker** est traité à part : le script installe le paquet fourni
> par les dépôts officiels de la distribution (`docker.io` sur Debian/Ubuntu,
> `docker` ailleurs) puis active le service via `systemd` lorsqu'il est présent.

---

## Prérequis

- Un système **Linux** disposant de l'un des gestionnaires ci-dessus.
- **Bash 4+** (utilisation de tableaux).
- Les **privilèges root**, soit en lançant le script avec `sudo`, soit en étant
  déjà `root`. En l'absence de droits root et hors `--dry-run`, le script
  s'arrête avec un message explicite.
- Pour la cible `lint` du Makefile : [`shellcheck`](https://www.shellcheck.net/).

> macOS / Windows ne sont pas pris en charge : le script s'arrête proprement si
> `uname -s` ne renvoie pas `Linux`.

---

## Structure du projet

```
scripting-onboarding/
├── onboard.sh           # Script principal (orchestration + options CLI)
├── packages.conf        # Listes de paquets par profil (ÉDITABLE)
├── lib/
│   ├── log.sh           # Journalisation horodatée et colorée
│   ├── detect-os.sh     # Détection distro + gestionnaire de paquets
│   └── packages.sh      # Abstraction d'installation (apt/dnf/pacman/zypper/yum)
├── Makefile             # Cibles : run / dry-run / lint / help
├── README.md            # Ce fichier
├── LICENSE              # Licence MIT
└── .gitignore
```

---

## Installation

```bash
git clone <url-du-depot> scripting-onboarding
cd scripting-onboarding
chmod +x onboard.sh        # rend le script exécutable si nécessaire
```

Aucune autre dépendance n'est à installer : les bibliothèques sont des fichiers
Bash sourcés depuis `lib/`.

---

## Usage

```bash
./onboard.sh --help
```

### Options

| Option                     | Description                                                              |
|----------------------------|--------------------------------------------------------------------------|
| `-p, --profile <minimal\|dev>` | Profil d'outils à installer. Défaut : `DEFAULT_PROFILE` de `packages.conf`. |
| `-y, --yes`                | Mode non interactif (répond « oui » aux invites du gestionnaire).        |
| `-n, --dry-run`            | Affiche les commandes sans rien exécuter.                                |
| `--git-name <nom>`         | Configure `git config --global user.name`.                               |
| `--git-email <email>`      | Configure `git config --global user.email`.                              |
| `--skip-docker-group`      | N'ajoute pas l'utilisateur au groupe `docker`.                           |
| `-h, --help`               | Affiche l'aide et quitte.                                                |

Variables d'environnement utiles :

- `NO_COLOR`, désactive la couleur des journaux si définie ;
- `LOG_LEVEL`, `DEBUG`, `INFO` (défaut), `WARN` ou `ERROR`.

### Exemples concrets

```bash
# 1) Première approche recommandée : tout prévisualiser sans rien modifier.
./onboard.sh --dry-run --profile dev

# 2) Installation complète, non interactive, avec configuration Git.
sudo ./onboard.sh --yes --profile dev \
     --git-name "Jane Doe" --git-email "jane@example.com"

# 3) Profil minimal seulement (poste léger / serveur).
sudo ./onboard.sh --yes --profile minimal

# 4) Sans toucher au groupe docker, en mode verbeux.
LOG_LEVEL=DEBUG sudo ./onboard.sh --yes --profile dev --skip-docker-group

# 5) Sortie sans couleur (journalisation vers un fichier).
NO_COLOR=1 ./onboard.sh --dry-run 2> onboarding.log
```

### Via le Makefile

```bash
make help                                   # liste les cibles
make dry-run PROFILE=dev                     # aperçu sans modification
make run PROFILE=minimal YES=1               # installation réelle non interactive
make run PROFILE=dev YES=1 \
     GIT_NAME="Jane Doe" GIT_EMAIL=jane@example.com
make lint                                    # analyse shellcheck des scripts
```

---

## Personnalisation (`packages.conf`)

Le fichier [`packages.conf`](packages.conf) est conçu pour être édité. Il définit
le profil par défaut et les listes de paquets sous forme de tableaux Bash :

```bash
DEFAULT_PROFILE="dev"

PACKAGES_MINIMAL=(
  ca-certificates
  curl
  wget
  git
  vim
  unzip
)

PACKAGES_DEV=(
  ca-certificates curl wget git vim unzip
  htop jq docker
)
```

- Les noms sont **génériques** : `onboard.sh` les traduit au besoin vers le nom
  réel du gestionnaire (voir `map_package_name` dans `lib/packages.sh`).
- Le pseudo-paquet `docker` déclenche l'installation du **moteur Docker**
  (et non un simple paquet du même nom).
- Pour ajouter un outil partout, ajoutez simplement son nom à la liste voulue.

---

## Idempotence et sécurité

- **Idempotent** : les paquets déjà installés sont détectés et ignorés ; les
  options `--needed` (pacman) et les vérifications `dpkg/rpm` évitent les
  réinstallations inutiles ; l'ajout au groupe `docker` n'est fait que si
  l'utilisateur n'en est pas déjà membre.
- **`set -euo pipefail`** : le script s'arrête à la première erreur, sur
  variable non définie, et propage les échecs dans les pipes.
- **`--dry-run`** : toutes les commandes système passent par `run_cmd`, qui les
  affiche au lieu de les exécuter en mode aperçu, idéal pour auditer avant
  d'agir.
- **Privilèges** : `sudo` n'est utilisé que lorsque c'est nécessaire ; en root,
  aucun préfixe n'est ajouté. L'ajout au groupe `docker` cible l'utilisateur
  réel (`SUDO_USER`) et non `root`.
- **Codes de sortie** documentés (voir `--help`) pour une intégration en CI ou
  dans d'autres scripts.

---

## Ce que ce projet démontre

- La conception d'un **script Bash de qualité production** : `set -euo pipefail`,
  analyse d'arguments robuste (formes `--opt value` et `--opt=value`), aide
  intégrée, codes de sortie explicites, journalisation horodatée et colorée.
- Une **architecture modulaire** : bibliothèques sourcées (`log.sh`,
  `detect-os.sh`, `packages.sh`) avec gardes anti-double-inclusion, séparant
  clairement les responsabilités.
- La **portabilité multi-distributions** via une couche d'abstraction au-dessus
  de cinq gestionnaires de paquets.
- Les bonnes pratiques **DevOps** : idempotence, mode `--dry-run`,
  configuration externalisée et éditable, `Makefile` de commodité, propreté
  `shellcheck`.

---

## Licence

Distribué sous licence **MIT**. Voir le fichier [LICENSE](LICENSE).

© 2026 Noumabeu Moutacdie Jordan
