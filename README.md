# Administration familiale

Site web statique pour gérer les informations administratives d'une famille élargie,
adossé à une base Supabase.

## Fonctionnalités

- Accès aux données protégé par mot de passe : **chaque requête de lecture/écriture**
  vers la base transporte le mot de passe, vérifié côté serveur (bcrypt) à chaque appel.
- Tableau principal de tous les membres, triés par jour de l'année de naissance
  (anniversaires) : prénom, nom, date de naissance, âge.
- Barre de recherche portant sur **tous les champs** d'un membre, y compris les noms
  des membres liés (parents, enfants, frères et sœurs).
- Fiche détaillée par membre : nom, prénom, sexe, date de naissance, adresse, email,
  date de mariage (facultatif), date de décès (facultatif), relations.
- Les relations sont modélisées par des liens parent → enfant ; les pères/mères et
  enfants sont stockés, les frères et sœurs sont déduits automatiquement.
- Comptes utilisateurs avec deux rôles : `admin` (lecture + écriture + gestion des
  comptes) et `viewer` (lecture seule). Les écritures sont refusées côté serveur
  pour les non-admins, pas seulement cachées dans l'interface.

## Sécurité

- Les données ne sont accessibles **que** via les fonctions RPC (`get_members`,
  `upsert_member`, `set_parent`, …) : les tables sont protégées par RLS sans aucune
  policy, donc l'accès direct depuis le navigateur avec la clé anon est refusé.
- Les mots de passe sont stockés hachés avec bcrypt (`pgcrypto`), jamais en clair.
- Il ne peut jamais exister moins d'un compte administrateur actif.
- Limitation connue : pas de anti brute-force natif sur les appels RPC PostgREST ;
  utilisez des mots de passe longs et remplacez les mots de passe initiaux
  immédiatement.

## Mise en place

1. **Créer le projet Supabase**
   - Créez un projet sur [supabase.com](https://supabase.com).
   - Ouvrez le *SQL Editor* et exécutez l'intégralité de `supabase/schema.sql`.

2. **Changer les mots de passe initiaux**
   Dans le SQL Editor :
   ```sql
   update app_users set password_hash = crypt('VOTRE_MOT_DE_PASSE_ADMIN', gen_salt('bf', 12)) where username = 'admin';
   update app_users set password_hash = crypt('VOTRE_MOT_DE_PASSE_FAMILLE', gen_salt('bf', 12)) where username = 'famille';
   ```

3. **Configurer le frontend**
   Dans le Dashboard Supabase (*Settings → API*), récupérez l'URL du projet et la
   clé `anon` et renseignez-les dans `js/config.js`. La clé `anon` est publique par
   conception : c'est la RLS qui protège les données, pas la clé.

4. **Héberger le site statique**
   - `index.html`, `styles.css` et `js/` peuvent être servis depuis n'importe quel
     hébergeur statique (GitHub Pages, Netlify, etc.).
   - Pour GitHub Pages : poussez le dépôt puis *Settings → Pages → Deploy from
     branch → main / (root)*.

## Créer des comptes supplémentaires

Connectez-vous sur le site avec le compte `admin`, ouvrez « Utilisateurs » :
vous pouvez y créer des comptes (lecture seule ou admin), changer un mot de passe,
désactiver ou supprimer un compte.

## Structure du projet

```
├── index.html              Page unique (connexion, tableau, fiches, comptes)
├── styles.css
├── js/
│   ├── config.js           URL et clé anon Supabase (à renseigner)
│   └── app.js              Logique de l'application
└── supabase/
    └── schema.sql          Tables, RLS, fonctions RPC, comptes initiaux
```
