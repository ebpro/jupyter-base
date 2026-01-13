# Content Metadata Conventions

Ce document définit les conventions pour les métadonnées des documents Quarto dans ce projet.

## Structure des métadonnées front-matter

```yaml
---
title: "Titre du contenu"
subtitle: "Sous-titre optionnel"
description: "Description courte pour la galerie (1-2 phrases)"
image: _quarto-utils/MyMedia/images/optimized/nom-image-400.webp
jupyter: python  # ou java, julia, etc.

categories:
  - [Type de contenu]  # Un seul type (voir ci-dessous)
  - [Contexte technique]  # Tags libres (Java, Docker, Git, etc.)
  - [Code de cours]  # PO43, I111, etc.

provide_notes: true    # false si pas de version notes
provide_slides: true   # false si pas de version slides
---
```

## 1. Propriétés de format (`provide_*`)

Ces propriétés indiquent **quels formats sont disponibles** pour ce contenu :

| Propriété | Valeurs | Description |
|-----------|---------|-------------|
| `provide_notes` | `true` / `false` | Document de notes (HTML long-form) |
| `provide_slides` | `true` / `false` | Présentation slides (Reveal.js) |

**Best practices :**
- Par défaut : `provide_notes: true`, `provide_slides: true`
- Omettre une propriété équivaut à `true` (comportement par défaut)
- Mettre explicitement à `false` pour masquer un bouton dans la galerie
- Les exercices/labs n'ont généralement pas de slides → `provide_slides: false`
- Les références rapides peuvent ne pas avoir de notes complètes → `provide_notes: false`

**Exemples :**
```yaml
# Cours magistral complet
provide_notes: true
provide_slides: true

# TP pratique sans slides
provide_notes: true
provide_slides: false

# Slides de présentation uniquement
provide_notes: false
provide_slides: true
```

## 2. Types de contenu (catégories principales)

**Un seul type par document** (première catégorie recommandée) :

| Type | Usage | Icône suggérée | `provide_slides` typique |
|------|-------|----------------|-------------------------|
| **Lecture** | Cours magistral, présentation théorique | 📚 `bi-book` | `true` |
| **Tutorial** | Guide pas-à-pas, apprentissage progressif | 🎓 `bi-mortarboard` | `false` |
| **Practice** | Exercices guidés avec solutions | ✏️ `bi-pencil-square` | `false` |
| **Lab** | Travaux pratiques, sessions hands-on | 🔬 `bi-laptop` | `false` |
| **Demo** | Démonstration technique, showcase | 🎬 `bi-play-circle` | `true` |
| **Workshop** | Atelier interactif, session collaborative | 🛠️ `bi-tools` | `false` |
| **Reference** | Documentation de référence, cheat sheet | 📖 `bi-journal-code` | `false` |
| **Assessment** | Quiz, évaluation, examen | ✅ `bi-check-circle` | `false` |
| **Case Study** | Étude de cas réelle, projet appliqué | 💼 `bi-briefcase` | `false` |

**Exemples :**
```yaml
categories:
  - Lecture      # Type principal
  - Docker       # Technologie
  - PO43         # Code cours
```

```yaml
categories:
  - Practice     # Type principal
  - Java         # Technologie
  - I111         # Code cours
```

## 3. Tags de contexte technique (catégories libres)

Tags libres pour décrire les **technologies, outils, ou concepts** abordés :

### Technologies & Langages
- `Python`, `Java`, `JavaScript`, `TypeScript`, `C`, `C++`, `Rust`, `Go`
- `SQL`, `NoSQL`, `MongoDB`, `PostgreSQL`
- `HTML`, `CSS`, `React`, `Vue`, `Angular`

### Outils & Plateformes
- `Docker`, `Kubernetes`, `Git`, `GitHub`, `GitLab`
- `Linux`, `Windows`, `macOS`
- `VS Code`, `IntelliJ`, `Eclipse`
- `Jupyter`, `Quarto`, `Markdown`

### Concepts & Domaines
- `OOP` (Object-Oriented Programming)
- `Functional Programming`
- `Data Science`, `Machine Learning`, `AI`
- `Web Development`, `Mobile Development`
- `DevOps`, `CI/CD`
- `Security`, `Cryptography`
- `Algorithms`, `Data Structures`
- `Testing`, `Debugging`
- `Architecture`, `Design Patterns`

### Méthodologies
- `Agile`, `Scrum`, `TDD`, `BDD`

**Best practices :**
- Utiliser 2-5 tags par document
- Préférer les noms anglais standards (meilleure recherche)
- Garder la cohérence : toujours `Docker` (pas `docker` ou `DOCKER`)
- Ne pas répéter le type de contenu dans les tags

## 4. Codes de cours

Identifiants des cours/modules (format libre selon votre institution) :

```yaml
categories:
  - Lecture
  - Java
  - PO43    # Code du cours
  - I111    # Autre code si applicable
```

## 5. Images

**Convention :**
```yaml
image: _quarto-utils/MyMedia/images/optimized/nom-descriptif-400.webp
```

**Best practices :**
- Toujours pointer vers la version `-400.webp` (le template génère automatiquement le srcset)
- Nommer les images de façon descriptive : `nom-auteur-unsplash_sujet-400.webp`
- Placer les images originales dans `_quarto-utils/MyMedia/images/`
- Les variantes optimisées (`-400.webp`, `-800.webp`) sont dans `optimized/`
- Lancer `./pre-render.sh` avant le render pour générer les variantes

## Exemples complets

### Cours magistral complet
```yaml
---
title: "Introduction à Docker"
subtitle: "Containers et Orchestration"
description: "Introduction complète aux containers Docker : concepts, commandes de base, et premiers déploiements."
image: _quarto-utils/MyMedia/images/optimized/ian-taylor-docker-400.webp
jupyter: python

categories:
  - Lecture
  - Docker
  - DevOps
  - PO43

provide_notes: true
provide_slides: true
---
```

### TP pratique
```yaml
---
title: "TP Java - POO"
subtitle: "Exercices sur l'héritage et le polymorphisme"
description: "Série d'exercices pratiques pour maîtriser l'héritage et le polymorphisme en Java avec tests unitaires."
image: _quarto-utils/MyMedia/images/optimized/taiki-ishikawa-java-400.webp
jupyter: java

categories:
  - Practice
  - Java
  - OOP
  - I111

provide_notes: true
provide_slides: false
---
```

### Démo technique
```yaml
---
title: "Demo Git Flow"
subtitle: "Branching Strategy"
description: "Démonstration interactive du workflow Git Flow pour les projets collaboratifs."
image: _quarto-utils/MyMedia/images/optimized/git-workflow-400.webp

categories:
  - Demo
  - Git
  - DevOps

provide_notes: false
provide_slides: true
---
```

### Documentation de référence
```yaml
---
title: "Python Cheat Sheet"
subtitle: "Syntaxe et Fonctions Essentielles"
description: "Aide-mémoire rapide pour la syntaxe Python : structures de données, contrôle de flux, fonctions courantes."
image: _quarto-utils/MyMedia/images/optimized/python-reference-400.webp
jupyter: python

categories:
  - Reference
  - Python
  - Data Science

provide_notes: true
provide_slides: false
---
```

## Workflow recommandé

1. **Créer le document** `.qmd` avec les métadonnées complètes
2. **Ajouter une image** dans `_quarto-utils/MyMedia/images/`
3. **Générer les variantes** : `./pre-render.sh` (crée les `-400.webp` et `-800.webp`)
4. **Render** : `quarto render --profile notes` ou `make render`
5. **Vérifier** la galerie dans `_output/index.html`

## Migration de contenus existants

Pour mettre à jour un ancien document :

```yaml
# Avant
---
title: "Mon cours"
---

# Après
---
title: "Mon cours"
subtitle: "Sous-titre descriptif"
description: "Description courte pour la galerie (max 2 phrases)."
image: _quarto-utils/MyMedia/images/optimized/image-sujet-400.webp

categories:
  - Lecture          # Type de contenu
  - [Technologie]    # Tag technique
  - [Code cours]     # Identifiant cours

provide_notes: true
provide_slides: true
---
```

## Notes supplémentaires

- La propriété `jupyter: <kernel>` indique quel kernel utiliser (python, java, julia, etc.)
- La `description` apparaît dans la carte de galerie (limiter à ~100-150 caractères)
- Le `subtitle` apparaît sous le titre principal dans la galerie
- Les catégories sont utilisées pour le filtrage et l'affichage de badges

---

**Dernière mise à jour :** 10 janvier 2026

## 6. Programmes et codes de cours — format inline

Pour déclarer les formations et leurs codes de cours associés directement dans le frontmatter (sans fichier YAML externe), utilisez le format :

```yaml
programs:
  - ProgramName [COURSE_CODE1]
  - AnotherProgram [CODE1, CODE2]
```

**Exemples :**
```yaml
programs:
  - M1-InfoMath [I111]
  - CNAM-I [PO43]
```

Pour un programme avec plusieurs codes :
```yaml
programs:
  - MSc-DS [I111, PO43, DEV-EXP]
```

**Règles :**
- Chaque entrée commence par le nom du programme, suivi des codes entre crochets `[...]`
- Plusieurs codes peuvent être séparés par des virgules ou espaces
- Les codes sont automatiquement extraits et affichés comme badges dans la galerie
- Les noms de programme (avant les crochets) sont affichés comme badges de programme

**Comportement dans la galerie :**
- La template `gallery.ejs` parse automatiquement ce format
- Affiche les noms de programme comme badges `.program-badge`
- Extrait et affiche les codes de cours comme badges `.code-badge`

**Pourquoi ce format :**
- Autonome : chaque document déclare explicitement ses formations et codes
- Portable : pas de dépendance à un registre externe (`programs.yml`)
- Clair : la correspondance programme → codes est visible directement dans le frontmatter

---
