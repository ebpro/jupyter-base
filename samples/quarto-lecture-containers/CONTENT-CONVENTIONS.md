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

## 6. Registre des formations (`programs`) — recommandation

Pour gérer le fait que les mêmes `course_codes` ne s'appliquent pas à toutes les formations, nous recommandons de centraliser la correspondance formation → codes de cours dans un registre `programs`.

Format recommandé (YAML). Placez ce bloc dans un fichier de données project-level (par ex. `_quarto-utils/programs.yml`) ou conservez une section d'exemple ici pour référence :

```yaml
programs:
  MSc-DS:
    name: "MSc Data Science"
    course_codes: [I111, PO43]
  Bootcamp-Java:
    name: "Bootcamp Java"
    course_codes: [BJ-01]
  Continuing-Ed:
    name: "Continuing Education"
    course_codes: [CE-2026]
```

Recommandations d'usage :
- Dans le frontmatter d'un document, **référencer les programmes par ID** :

```yaml
programs:
  - MSc-DS
  - Bootcamp-Java
```

- Ne dupliquez pas systématiquement `course_codes` dans le frontmatter. Si `course_codes` est absent, la template peut récupérer les codes depuis le(s) `programs` référencés. Si un document a besoin d'un code spécifique différent, **utilisez `course_codes` en override explicite**.

- Conserver un registre central facilite le renommage des programmes, la recherche et le filtrage par formation.

Template & implémentation :
- La galerie lit `item.programs` (frontmatter) et, si un registre global est disponible (par ex. `site.programs` ou `_quarto-utils/programs.yml` importé comme données), elle peut rechercher les `course_codes` associés. Le frontmatter `course_codes` a priorité sur les codes dérivés du registre.

---
