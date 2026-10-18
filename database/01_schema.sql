/* =====================================================================
   CareFlow - 01_schema.sql  (version 2 : UN SEUL etablissement)
   Tables, contraintes, index et triggers.
   A executer UNE SEULE FOIS sur une base vide (voir 00_reset_dev.sql
   pour repartir de zero en developpement).
   Regles : dates en UTC, aucune donnee clinique, priorite saisie par un humain.
   Fichier volontairement sans accents (compatibilite SSMS).
   ===================================================================== */
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

/* ---------- Parametres de l'etablissement (UNE SEULE ligne, Id = 1) ----------
   Regroupe l'identite de l'etablissement et les regles validees par lui
   (poids du classement, delais). */
CREATE TABLE dbo.ParametreEtablissement (
    Id                          TINYINT      NOT NULL CONSTRAINT PK_ParametreEtablissement PRIMARY KEY
                                             CONSTRAINT DF_Param_Id DEFAULT (1)
                                             CONSTRAINT CK_Param_UneLigne CHECK (Id = 1),
    NomEtablissement            NVARCHAR(150) NOT NULL,
    Ville                       NVARCHAR(80)  NOT NULL,
    Region                      NVARCHAR(80)  NOT NULL,
    Telephone                   NVARCHAR(30)  NULL,
    PoidsPriorite               DECIMAL(6,2) NOT NULL CONSTRAINT DF_Param_PP DEFAULT (10),
    PoidsAnciennete             DECIMAL(6,2) NOT NULL CONSTRAINT DF_Param_PA DEFAULT (1),   -- par jour d'attente
    PoidsProximite              DECIMAL(6,2) NOT NULL CONSTRAINT DF_Param_PX DEFAULT (3),   -- ville=2, region=1, sinon 0
    DelaiAcceptationMinutes     INT          NOT NULL CONSTRAINT DF_Param_DA DEFAULT (60)
                                             CONSTRAINT CK_Param_DA CHECK (DelaiAcceptationMinutes > 0),
    DelaiMinAvantCreneauMinutes INT          NOT NULL CONSTRAINT DF_Param_DM DEFAULT (60)
                                             CONSTRAINT CK_Param_DM CHECK (DelaiMinAvantCreneauMinutes >= 0),
    MaxInscriptionsActives      INT          NOT NULL CONSTRAINT DF_Param_MI DEFAULT (3)
                                             CONSTRAINT CK_Param_MI CHECK (MaxInscriptionsActives >= 1),
    DecalageUtcMinutes          INT          NOT NULL CONSTRAINT DF_Param_DU DEFAULT (60),  -- Cameroun = UTC+1
    ValideParEtablissement      BIT          NOT NULL CONSTRAINT DF_Param_Val DEFAULT (0),
    DateValidationUtc           DATETIME2(0) NULL
);
GO

/* ---------- Referentiels ---------- */
CREATE TABLE dbo.Specialite (
    Id         INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_Specialite PRIMARY KEY,
    Nom        NVARCHAR(100) NOT NULL CONSTRAINT UQ_Specialite_Nom UNIQUE,
    EstArchive BIT NOT NULL CONSTRAINT DF_Specialite_Archive DEFAULT (0)
);
GO

CREATE TABLE dbo.Praticien (
    Id              INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_Praticien PRIMARY KEY,
    SpecialiteId    INT NOT NULL CONSTRAINT FK_Praticien_Spec REFERENCES dbo.Specialite(Id),
    Nom             NVARCHAR(150) NOT NULL,
    EstArchive      BIT NOT NULL CONSTRAINT DF_Praticien_Archive DEFAULT (0),
    DateCreationUtc DATETIME2(0) NOT NULL CONSTRAINT DF_Praticien_Date DEFAULT (SYSUTCDATETIME())
);
CREATE INDEX IX_Praticien_Spec ON dbo.Praticien(SpecialiteId);
GO

/* ---------- Utilisateurs (donnees minimales : pas de date de naissance, pas de motif) ---------- */
CREATE TABLE dbo.Utilisateur (
    Id              INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_Utilisateur PRIMARY KEY,
    Nom             NVARCHAR(150) NOT NULL,
    Email           NVARCHAR(256) NULL,
    Telephone       NVARCHAR(30)  NULL,
    MotDePasseHash  NVARCHAR(256) NULL,   -- hash cote application (jamais de mot de passe en clair)
    Role            VARCHAR(25)   NOT NULL
                    CONSTRAINT CK_Utilisateur_Role CHECK (Role IN ('Patient','PraticienSecretariat','Etablissement','Administrateur')),
    PraticienId     INT NULL CONSTRAINT FK_Utilisateur_Prat REFERENCES dbo.Praticien(Id),
    Ville           NVARCHAR(80) NULL,
    Region          NVARCHAR(80) NULL,
    EstActif        BIT NOT NULL CONSTRAINT DF_Utilisateur_Actif DEFAULT (1),
    EstSuspendu     BIT NOT NULL CONSTRAINT DF_Utilisateur_Susp DEFAULT (0),
    ContactVerifie  BIT NOT NULL CONSTRAINT DF_Utilisateur_CV DEFAULT (0),
    DateCreationUtc DATETIME2(0) NOT NULL CONSTRAINT DF_Utilisateur_Date DEFAULT (SYSUTCDATETIME()),
    CONSTRAINT CK_Utilisateur_Contact CHECK (Email IS NOT NULL OR Telephone IS NOT NULL)
);
CREATE UNIQUE INDEX UX_Utilisateur_Email ON dbo.Utilisateur(Email)     WHERE Email IS NOT NULL;
CREATE UNIQUE INDEX UX_Utilisateur_Tel   ON dbo.Utilisateur(Telephone) WHERE Telephone IS NOT NULL;
GO

/* ---------- Creneaux ----------
   Etats : Libre -> Reserve ; Reserve -> DerniereMinute (annulation) ;
   DerniereMinute -> Propose (offre en cours) ; Propose -> Reserve (accepte)
   ou retour a DerniereMinute (refus / expiration) ; Termine ; Annule (retire du planning). */
CREATE TABLE dbo.Creneau (
    Id              INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_Creneau PRIMARY KEY,
    PraticienId     INT NOT NULL CONSTRAINT FK_Creneau_Prat REFERENCES dbo.Praticien(Id),
    DebutUtc        DATETIME2(0) NOT NULL,
    FinUtc          DATETIME2(0) NOT NULL,
    Statut          VARCHAR(15) NOT NULL CONSTRAINT DF_Creneau_Statut DEFAULT ('Libre')
                    CONSTRAINT CK_Creneau_Statut CHECK (Statut IN ('Libre','Reserve','DerniereMinute','Propose','Termine','Annule')),
    DateStatutUtc   DATETIME2(0) NOT NULL CONSTRAINT DF_Creneau_DateStatut DEFAULT (SYSUTCDATETIME()),
    Version         ROWVERSION,
    CONSTRAINT CK_Creneau_Dates CHECK (FinUtc > DebutUtc)
);
CREATE UNIQUE INDEX UX_Creneau_Praticien_Debut ON dbo.Creneau(PraticienId, DebutUtc) WHERE Statut <> 'Annule';
CREATE INDEX IX_Creneau_Statut ON dbo.Creneau(Statut, DebutUtc);
GO

CREATE TABLE dbo.Reservation (
    Id                 INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_Reservation PRIMARY KEY,
    CreneauId          INT NOT NULL CONSTRAINT FK_Reservation_Creneau REFERENCES dbo.Creneau(Id),
    PatientId          INT NOT NULL CONSTRAINT FK_Reservation_Patient REFERENCES dbo.Utilisateur(Id),
    DateDemandeUtc     DATETIME2(0) NOT NULL,   -- debut de l'attente (inscription liste d'attente ou reservation directe)
    DateReservationUtc DATETIME2(0) NOT NULL CONSTRAINT DF_Reservation_Date DEFAULT (SYSUTCDATETIME()),
    Origine            VARCHAR(15) NOT NULL CONSTRAINT CK_Reservation_Origine CHECK (Origine IN ('Directe','ListeAttente')),
    Statut             VARCHAR(10) NOT NULL CONSTRAINT DF_Reservation_Statut DEFAULT ('Active')
                       CONSTRAINT CK_Reservation_Statut CHECK (Statut IN ('Active','Annulee')),
    DateAnnulationUtc  DATETIME2(0) NULL,
    AnnuleePar         INT NULL CONSTRAINT FK_Reservation_AnnuleePar REFERENCES dbo.Utilisateur(Id)
);
-- Garantie ultime : une seule reservation active par creneau
CREATE UNIQUE INDEX UX_Reservation_Active ON dbo.Reservation(CreneauId) WHERE Statut = 'Active';
CREATE INDEX IX_Reservation_Patient ON dbo.Reservation(PatientId, Statut);
GO

/* ---------- Liste d'attente ---------- */
CREATE TABLE dbo.ListeAttente (
    Id                 INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_ListeAttente PRIMARY KEY,
    PatientId          INT NOT NULL CONSTRAINT FK_LA_Patient REFERENCES dbo.Utilisateur(Id),
    SpecialiteId       INT NOT NULL CONSTRAINT FK_LA_Spec REFERENCES dbo.Specialite(Id),
    Ville              NVARCHAR(80) NOT NULL,
    Region             NVARCHAR(80) NOT NULL,
    Priorite           TINYINT NOT NULL CONSTRAINT DF_LA_Priorite DEFAULT (0)
                       CONSTRAINT CK_LA_Priorite CHECK (Priorite BETWEEN 0 AND 2),  -- saisie humaine, 2 = plus prioritaire
    PrioriteSaisiePar  INT NULL CONSTRAINT FK_LA_PrioritePar REFERENCES dbo.Utilisateur(Id),
    DateInscriptionUtc DATETIME2(0) NOT NULL CONSTRAINT DF_LA_Date DEFAULT (SYSUTCDATETIME()),
    Statut             VARCHAR(12) NOT NULL CONSTRAINT DF_LA_Statut DEFAULT ('Active')
                       CONSTRAINT CK_LA_Statut CHECK (Statut IN ('Active','Satisfaite','Annulee')),
    DateFinUtc         DATETIME2(0) NULL
);
CREATE UNIQUE INDEX UX_LA_Active ON dbo.ListeAttente(PatientId, SpecialiteId) WHERE Statut = 'Active';
CREATE INDEX IX_LA_Recherche ON dbo.ListeAttente(SpecialiteId, Statut);
GO

/* Disponibilites du patient (heure LOCALE de l'etablissement). Jour : 1 = lundi ... 7 = dimanche */
CREATE TABLE dbo.DisponibiliteAttente (
    Id             INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_Disponibilite PRIMARY KEY,
    ListeAttenteId INT NOT NULL CONSTRAINT FK_Dispo_LA REFERENCES dbo.ListeAttente(Id) ON DELETE CASCADE,
    JourSemaine    TINYINT NOT NULL CONSTRAINT CK_Dispo_Jour CHECK (JourSemaine BETWEEN 1 AND 7),
    HeureDebut     TIME(0) NOT NULL,
    HeureFin       TIME(0) NOT NULL,
    CONSTRAINT CK_Dispo_Heures CHECK (HeureFin > HeureDebut)
);
CREATE INDEX IX_Dispo_LA ON dbo.DisponibiliteAttente(ListeAttenteId, JourSemaine);
GO

/* ---------- Offres ---------- */
CREATE TABLE dbo.Offre (
    Id                INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_Offre PRIMARY KEY,
    CreneauId         INT NOT NULL CONSTRAINT FK_Offre_Creneau REFERENCES dbo.Creneau(Id),
    ListeAttenteId    INT NOT NULL CONSTRAINT FK_Offre_LA REFERENCES dbo.ListeAttente(Id),
    PatientId         INT NOT NULL CONSTRAINT FK_Offre_Patient REFERENCES dbo.Utilisateur(Id),
    Score             DECIMAL(10,2) NOT NULL,   -- score enregistre pour que la regle soit verifiable
    DateOffreUtc      DATETIME2(0) NOT NULL,
    DateExpirationUtc DATETIME2(0) NOT NULL,
    Statut            VARCHAR(10) NOT NULL CONSTRAINT DF_Offre_Statut DEFAULT ('EnAttente')
                      CONSTRAINT CK_Offre_Statut CHECK (Statut IN ('EnAttente','Acceptee','Refusee','Expiree')),
    DateReponseUtc    DATETIME2(0) NULL
);
-- Un creneau ne peut etre propose qu'a UN SEUL patient a la fois
CREATE UNIQUE INDEX UX_Offre_EnAttente ON dbo.Offre(CreneauId) WHERE Statut = 'EnAttente';
CREATE INDEX IX_Offre_Expiration ON dbo.Offre(DateExpirationUtc) WHERE Statut = 'EnAttente';
CREATE INDEX IX_Offre_Patient ON dbo.Offre(PatientId, Statut);
GO

/* ---------- Notifications simulees ---------- */
CREATE TABLE dbo.Notification (
    Id              INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_Notification PRIMARY KEY,
    UtilisateurId   INT NOT NULL CONSTRAINT FK_Notif_User REFERENCES dbo.Utilisateur(Id),
    Canal           VARCHAR(10) NOT NULL CONSTRAINT CK_Notif_Canal CHECK (Canal IN ('SMS','Email')),
    Type            VARCHAR(30) NOT NULL,
    Message         NVARCHAR(500) NOT NULL,
    DateCreationUtc DATETIME2(0) NOT NULL CONSTRAINT DF_Notif_Date DEFAULT (SYSUTCDATETIME()),
    EstSimulee      BIT NOT NULL CONSTRAINT DF_Notif_Sim DEFAULT (1),
    EstLue          BIT NOT NULL CONSTRAINT DF_Notif_Lue DEFAULT (0)
);
CREATE INDEX IX_Notif_User ON dbo.Notification(UtilisateurId, DateCreationUtc DESC);
GO

/* ---------- Contenus statiques valides ---------- */
CREATE TABLE dbo.CapsuleInformation (
    Id                INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_Capsule PRIMARY KEY,
    Code              VARCHAR(50) NOT NULL,
    Version           INT NOT NULL CONSTRAINT DF_Capsule_Version DEFAULT (1),
    Categorie         VARCHAR(30) NOT NULL
                      CONSTRAINT CK_Capsule_Cat CHECK (Categorie IN ('Preparation','HygieneDeVie','QuandConsulterEnUrgence')),
    Titre             NVARCHAR(200) NOT NULL,
    Contenu           NVARCHAR(MAX) NOT NULL,
    Auteur            NVARCHAR(150) NOT NULL,
    ValidePar         NVARCHAR(150) NULL,
    DateValidationUtc DATETIME2(0) NULL,
    DateRevueUtc      DATETIME2(0) NULL,
    EstActive         BIT NOT NULL CONSTRAINT DF_Capsule_Active DEFAULT (0),
    CONSTRAINT UQ_Capsule_CodeVersion UNIQUE (Code, Version),
    -- une capsule ne peut etre active que si elle est validee (auteur + date de validation)
    CONSTRAINT CK_Capsule_Validee CHECK (EstActive = 0 OR (ValidePar IS NOT NULL AND DateValidationUtc IS NOT NULL))
);
GO

CREATE TABLE dbo.QuestionOrientation (
    Id        INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_QuestionOrientation PRIMARY KEY,
    Libelle   NVARCHAR(300) NOT NULL,
    Ordre     INT NOT NULL,
    EstActive BIT NOT NULL CONSTRAINT DF_Question_Active DEFAULT (0)
);
CREATE TABLE dbo.ReponseOrientation (
    Id           INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_ReponseOrientation PRIMARY KEY,
    QuestionId   INT NOT NULL CONSTRAINT FK_Reponse_Question REFERENCES dbo.QuestionOrientation(Id),
    Libelle      NVARCHAR(150) NOT NULL,
    EstAlarmante BIT NOT NULL CONSTRAINT DF_Reponse_Alarm DEFAULT (0)
);
-- Les REPONSES du patient ne sont jamais stockees (aucune table prevue a cet effet).

CREATE TABLE dbo.NumeroUrgence (
    Id      INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_NumeroUrgence PRIMARY KEY,
    Libelle NVARCHAR(100) NOT NULL,
    Numero  NVARCHAR(30)  NOT NULL,
    Ordre   INT NOT NULL CONSTRAINT DF_NumUrg_Ordre DEFAULT (1)
);
CREATE TABLE dbo.MessageUrgence (
    Id                INT IDENTITY(1,1) NOT NULL CONSTRAINT PK_MessageUrgence PRIMARY KEY,
    Texte             NVARCHAR(500) NOT NULL,
    ValidePar         NVARCHAR(150) NOT NULL,
    DateValidationUtc DATETIME2(0) NOT NULL
);
GO

/* ---------- Journal d'audit (ajout seul) ---------- */
CREATE TABLE dbo.JournalAudit (
    Id              BIGINT IDENTITY(1,1) NOT NULL CONSTRAINT PK_JournalAudit PRIMARY KEY,
    DateUtc         DATETIME2(3) NOT NULL CONSTRAINT DF_Audit_Date DEFAULT (SYSUTCDATETIME()),
    UtilisateurId   INT NULL,
    Action          VARCHAR(20) NOT NULL
                    CONSTRAINT CK_Audit_Action CHECK (Action IN ('Lecture','Creation','Modification','Suppression','AccesRefuse','Connexion')),
    Entite          VARCHAR(50) NOT NULL,
    EntiteId        INT NULL,
    Succes          BIT NOT NULL CONSTRAINT DF_Audit_Succes DEFAULT (1),
    Detail          NVARCHAR(300) NULL,   -- jamais de donnee de sante
    AdresseIp       VARCHAR(45) NULL
);
CREATE INDEX IX_Audit_Date ON dbo.JournalAudit(DateUtc);
CREATE INDEX IX_Audit_User ON dbo.JournalAudit(UtilisateurId, DateUtc);
GO

CREATE OR ALTER TRIGGER dbo.trg_JournalAudit_AjoutSeul
ON dbo.JournalAudit
INSTEAD OF UPDATE, DELETE
AS
BEGIN
    SET NOCOUNT ON;
    THROW 50001, N'Le journal d''audit est en ajout seul : modification et suppression interdites.', 1;
END
GO

/* Recommande aux comptes applicatifs (pas aux developpeurs proprietaires) :
   DENY UPDATE, DELETE ON dbo.JournalAudit TO [compte_application];  */
PRINT 'Schema CareFlow cree (etablissement unique).';
GO
