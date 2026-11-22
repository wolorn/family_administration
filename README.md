# Administration familiale

Site web statique pour gérer les informations administratives d'une famille élargie,
adossé à une base Supabase.

## Fonctionnalités

- Accès aux données protégé par mot de passe : **chaque requête de lecture/écriture**
  vers la base transporte le mot de passe, vérifié côté serveur (bcrypt) à chaque appel.
- Tableau principal de tous les membres, triés par jour de l'année de naissance
  (anniversaires) : prénom, nom, date de naissance, âge.
- Barre de recherche portant sur **tous les champs** d'un membre (adresse, dates,
  email…). Les relations ne déclenchent pas de résultat.
- Colonnes du tableau triables (clic sur l'en-tête, tri croissant/décroissant) ;
  tri par défaut : jour de l'année de naissance.
- Bouton d'export (Excel `.xlsx` ou Word `.doc`) avec choix des champs à inclure ;
  l'export respecte la recherche courante.
- Bouton « Arbre généalogique » : graphe SVG construit à partir des liens
  parent/enfant et des conjoints (clic sur une carte = ouverture de la fiche).
- Adresses cliquables vers une carte (geo: sur Android, Maps sur iOS, Google Maps
  sur ordinateur) et emails cliquables en `mailto:`.
- Adresse de substitution à l'affichage : si l'adresse postale d'un membre n'est
  pas renseignée, sa fiche affiche celle de son conjoint ; pour un mineur, celle
  d'un parent (texte grisé indiquant la provenance). Le formulaire d'édition ou
  de proposition ne modifie que l'adresse propre au membre — jamais celle du
  conjoint ou du parent.
- Bouton « Copier les emails » : liste de diffusion des membres affichés.
- Bandeau de vœux les jours d'anniversaire des membres vivants.
- Fiche détaillée par membre : nom, prénom, sexe, date de naissance, adresse, email,
  date de mariage (facultatif), date de décès (facultatif), relations.
- Les relations sont modélisées par des liens parent → enfant ; les pères/mères et
  enfants sont stockés, les frères et sœurs sont déduits automatiquement. Le conjoint
  est un lien symétrique, cohérencé automatiquement dans les deux sens.
- Le nom de la famille à administrer est configurable (table `app_settings`, lecture
  publique) et s'affiche en haut de la page, même avant connexion.
- Comptes utilisateurs avec deux rôles : `admin` (lecture + écriture + gestion des
  comptes) et `viewer` (lecture seule). Les écritures sont refusées côté serveur
  pour les non-admins, pas seulement cachées dans l'interface.
- **Propositions de modification** : un utilisateur non admin peut ouvrir la fiche
  d'un membre, cliquer « Proposer une modification » et corriger ou compléter les
  champs. Rien n'est publié immédiatement : la proposition est stockée, un email
  est envoyé aux administrateurs, et l'admin la retrouve dans « Modifications
  proposées » sous forme de comparaison avant/après (ancienne valeur barrée en
  rouge, valeur proposée en vert) avec boutons Accepter/Refuser. Accepter applique
  les données et les relations (père, mère, conjoint) proposées.
- **Propositions d'ajout** : un utilisateur non admin peut aussi proposer la
  création d'un nouveau membre (« Proposer l'ajout d'un membre ») ; l'admin
  voit les champs proposés (tous en vert) et l'acceptation crée le membre.

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
   - Exécutez ensuite les migrations, dans l'ordre : `02_family_name.sql`,
     `03_add_spouse.sql`, `04_grant_app_settings_anon.sql`,
     `05_member_proposals.sql`, `06_propose_new_members.sql` (le nom de famille
     par défaut « Ma Famille » se change dans la table `app_settings` :
     `update app_settings set value = '…' where key = 'family_name';`).

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

## Notifications email des propositions

L'email envoyé aux administrateurs lors d'une proposition passe par une
**fonction Edge** Supabase (`supabase/functions/notify-proposal`) qui envoie
les messages en SMTP via votre compte Proton Mail.

Pré-requis côté Proton : créez un **jeton SMTP** (Proton Mail →
*Tous les réglages → IMAP/SMTP → Jetons SMTP → Générer*) et notez le nom
d'utilisateur et le mot de passe de ce jeton.

Déploiement (Supabase CLI installée et projet lié) :

```sh
supabase functions deploy notify-proposal
supabase secrets set SMTP_USER="nom_utilisateur_du_jeton" \
  SMTP_PASS="mot_de_passe_du_jeton" \
  NOTIFY_FROM_EMAIL="vous@exemple.fr" \
  NOTIFY_TO_EMAILS="admin1@exemple.fr,admin2@exemple.fr"
```

Secrets :
- `SMTP_USER` / `SMTP_PASS` : identifiants du jeton SMTP Proton.
- `SMTP_HOST` / `SMTP_PORT` : facultatifs (défauts Proton :
  `smtp.protonmail.ch`, port `587`) — utiles si vous changez de fournisseur.
- `NOTIFY_FROM_EMAIL` : émetteur ; doit être l'adresse de votre compte
  Proton ou un de ses alias.
- `NOTIFY_TO_EMAILS` : adresses des administrateurs, séparées par des virgules.

L'équivalent est possible via le portail web : *Edge Functions → Create a new
function → Via Dashboard*, collez le code puis onglet *Secrets* de la fonction.

Si la fonction n'est pas déployée ou échoue, **la proposition reste tout de même
enregistrée** et visible dans « Modifications proposées » : seul l'email est
perdu.

## Structure du projet

```
├── index.html              Page unique (connexion, tableau, fiches, comptes, export, arbre)
├── styles.css
├── js/
│   ├── config.js           URL et clé anon Supabase (à renseigner)
│   ├── app.js              Logique applicative
│   ├── utils.js            Utilitaires partagés (dates, âge, liens carte/email)
│   ├── export.js           Export xlsx / Word avec choix des champs
│   └── tree.js             Arbre généalogique SVG
└── supabase/
    ├── schema.sql          Schema de référence (à exécuter une fois à l'installation)
    ├── migrations/         Modifications du schéma, un script numéroté par changement
    └── functions/
        └── notify-proposal/  Fonction Edge : email aux admins (Resend)
```

## Évolution du schéma

`supabase/schema.sql` est le schéma de référence executé à l'installation.
Toute modification ultérieure se fait dans un script dédié
`supabase/migrations/NN_description.sql`, à executer dans le SQL Editor de
Supabase dans l'ordre des numéros.
