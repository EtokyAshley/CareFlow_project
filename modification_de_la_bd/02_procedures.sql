/* =====================================================================
   CareFlow - 02_procedures.sql  (version 3 : MULTI-ETABLISSEMENTS)
   Procedures stockees de la liste d'attente.

   Transactions : chaque procedure ouvre sa propre transaction SEULEMENT si
   aucune n'est deja ouverte. Cote C#, on peut donc ouvrir une SqlTransaction
   ADO.NET et y executer plusieurs procedures : tout sera valide ou annule ensemble.

   Codes @Resultat :  0 = succes
                      1 = succes sans offre (aucun candidat, le creneau reste reservable)
                     -1 = introuvable   -2 = deja traite / indisponible
                     -3 = offre expiree -4 = acces refuse   -5 = trop tard
                     -6 = limite d'inscriptions atteinte    -7 = deja inscrit
   Les parametres (poids, delais, ville) sont lus dans la ligne Etablissement
   du creneau concerne : chaque etablissement a ses propres regles.
   NOTE : le controle d'acces (qui a le droit de toucher a quel etablissement)
   est fait par l'APPLICATION (services C#) ; ces procedures garantissent
   seulement que les candidats et les parametres sont ceux du bon etablissement.
   Fichier volontairement sans accents (compatibilite SSMS).
   ===================================================================== */
SET NOCOUNT ON;
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

/* ---------- Journal d'audit (ajout) ---------- */
CREATE OR ALTER PROCEDURE dbo.usp_EnregistrerAudit
    @UtilisateurId   INT = NULL,
    @Action          VARCHAR(20),
    @Entite          VARCHAR(50),
    @EntiteId        INT = NULL,
    @Succes          BIT = 1,
    @Detail          NVARCHAR(300) = NULL,
    @AdresseIp       VARCHAR(45) = NULL,
    @EtablissementId INT = NULL
AS
BEGIN
    SET NOCOUNT ON;
    INSERT INTO dbo.JournalAudit (UtilisateurId, EtablissementId, Action, Entite, EntiteId, Succes, Detail, AdresseIp)
    VALUES (@UtilisateurId, @EtablissementId, @Action, @Entite, @EntiteId, @Succes, @Detail, @AdresseIp);
END
GO

/* ---------- Proposer un creneau "derniere minute" au meilleur candidat ----------
   Classement : score = PoidsPriorite*Priorite + PoidsAnciennete*jours_attente + PoidsProximite*(ville=2, region=1)
   Les poids et la ville de reference sont ceux de l'ETABLISSEMENT du creneau.
   Candidats : uniquement les inscriptions de CET etablissement.
   Exclus : patient qui vient d'annuler ce creneau, patient deja sollicite pour ce creneau,
            patient suspendu/inactif, patient hors disponibilites, patient avec une offre deja en cours. */
CREATE OR ALTER PROCEDURE dbo.usp_ProposerCreneau
    @CreneauId INT,
    @OffreId   INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;

    DECLARE @Own BIT = IIF(@@TRANCOUNT = 0, 1, 0);
    DECLARE @Now DATETIME2(0) = SYSUTCDATETIME();
    DECLARE @Etab INT, @Spec INT, @Debut DATETIME2(0), @Fin DATETIME2(0), @Statut VARCHAR(15);
    DECLARE @wP DECIMAL(6,2) = 10, @wA DECIMAL(6,2) = 1, @wX DECIMAL(6,2) = 3;   -- valeurs par defaut si etablissement introuvable
    DECLARE @Delai INT = 60, @DelaiMin INT = 60, @Decal INT = 60;
    DECLARE @VilleE NVARCHAR(80) = NULL, @RegionE NVARCHAR(80) = NULL;
    DECLARE @Expire DATETIME2(0), @DebutLocal DATETIME2(0), @FinLocal DATETIME2(0);
    DECLARE @Jour TINYINT, @HD TIME(0), @HF TIME(0);
    DECLARE @LaId INT, @PatId INT, @Score DECIMAL(10,2);
    DECLARE @Msg NVARCHAR(500);

    SET @OffreId = NULL;
    IF @Own = 1 BEGIN TRANSACTION;

    BEGIN TRY
        -- Verrou sur le creneau : un seul traitement a la fois
        SELECT @Etab = p.EtablissementId, @Spec = p.SpecialiteId, @Debut = c.DebutUtc, @Fin = c.FinUtc, @Statut = c.Statut
        FROM dbo.Creneau AS c WITH (UPDLOCK, HOLDLOCK)
        JOIN dbo.Praticien AS p ON p.Id = c.PraticienId
        WHERE c.Id = @CreneauId;

        SELECT @wP = e.PoidsPriorite, @wA = e.PoidsAnciennete, @wX = e.PoidsProximite,
               @Delai = e.DelaiAcceptationMinutes, @DelaiMin = e.DelaiMinAvantCreneauMinutes,
               @Decal = e.DecalageUtcMinutes, @VilleE = e.Ville, @RegionE = e.Region
        FROM dbo.Etablissement AS e
        WHERE e.Id = @Etab;

        -- Seulement si le creneau est "derniere minute" et pas trop proche (R10)
        IF @Statut = 'DerniereMinute' AND DATEADD(MINUTE, -@DelaiMin, @Debut) > @Now
        BEGIN
            -- Delai d'acceptation adapte a l'echeance du creneau (R9)
            SET @Expire = (SELECT MIN(v) FROM (VALUES (DATEADD(MINUTE, @Delai, @Now)),
                                                      (DATEADD(MINUTE, -@DelaiMin, @Debut))) AS t(v));

            -- Heure locale du creneau et jour de semaine (1 = lundi), independant de DATEFIRST (R16)
            SET @DebutLocal = DATEADD(MINUTE, @Decal, @Debut);
            SET @FinLocal   = DATEADD(MINUTE, @Decal, @Fin);
            SET @Jour = ((DATEPART(WEEKDAY, @DebutLocal) + @@DATEFIRST - 2) % 7) + 1;
            SET @HD = CAST(@DebutLocal AS TIME(0));
            SET @HF = CAST(@FinLocal AS TIME(0));

            SELECT TOP (1) @LaId = la.Id, @PatId = la.PatientId, @Score = s.Score
            FROM dbo.ListeAttente AS la
            JOIN dbo.Utilisateur AS u ON u.Id = la.PatientId
            CROSS APPLY (SELECT CAST(@wP * la.Priorite
                                   + @wA * DATEDIFF(DAY, la.DateInscriptionUtc, @Now)
                                   + @wX * CASE WHEN la.Ville = @VilleE THEN 2
                                                WHEN la.Region = @RegionE THEN 1 ELSE 0 END
                                     AS DECIMAL(10,2)) AS Score) AS s
            WHERE la.Statut = 'Active'
              AND la.EtablissementId = @Etab          -- cloisonnement : seulement la liste de CET etablissement
              AND la.SpecialiteId = @Spec
              AND u.EstActif = 1 AND u.EstSuspendu = 0
              AND EXISTS (SELECT 1 FROM dbo.DisponibiliteAttente AS d
                          WHERE d.ListeAttenteId = la.Id AND d.JourSemaine = @Jour
                            AND d.HeureDebut <= @HD AND d.HeureFin >= @HF)
              AND NOT EXISTS (SELECT 1 FROM dbo.Reservation AS r
                              WHERE r.CreneauId = @CreneauId AND r.PatientId = la.PatientId AND r.Statut = 'Annulee')
              AND NOT EXISTS (SELECT 1 FROM dbo.Offre AS o1
                              WHERE o1.CreneauId = @CreneauId AND o1.PatientId = la.PatientId)
              AND NOT EXISTS (SELECT 1 FROM dbo.Offre AS o2
                              WHERE o2.PatientId = la.PatientId AND o2.Statut = 'EnAttente')
            ORDER BY s.Score DESC, la.DateInscriptionUtc ASC, la.Id ASC;

            IF @LaId IS NOT NULL
            BEGIN
                INSERT INTO dbo.Offre (CreneauId, ListeAttenteId, PatientId, Score, DateOffreUtc, DateExpirationUtc)
                VALUES (@CreneauId, @LaId, @PatId, @Score, @Now, @Expire);
                SET @OffreId = SCOPE_IDENTITY();

                UPDATE dbo.Creneau SET Statut = 'Propose', DateStatutUtc = @Now WHERE Id = @CreneauId;

                SET @Msg = N'CareFlow : un creneau est disponible le ' + CONVERT(NVARCHAR(16), @DebutLocal, 120)
                         + N'. Repondez avant ' + CONVERT(NVARCHAR(16), DATEADD(MINUTE, @Decal, @Expire), 120)
                         + N'. En cas d''aggravation, ne restez pas dans la file : rendez-vous aux urgences.';
                INSERT INTO dbo.Notification (UtilisateurId, Canal, Type, Message)
                VALUES (@PatId, 'SMS', 'OffreCreneau', @Msg);

                EXEC dbo.usp_EnregistrerAudit @UtilisateurId = NULL, @Action = 'Creation', @Entite = 'Offre',
                     @EntiteId = @OffreId, @Detail = N'Offre proposee automatiquement', @EtablissementId = @Etab;
            END
            -- Sinon : aucun candidat, le creneau reste "DerniereMinute" (reservable, sans erreur)
        END

        IF @Own = 1 COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @Own = 1 AND @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

/* ---------- Inscription a la liste d'attente d'un etablissement ---------- */
CREATE OR ALTER PROCEDURE dbo.usp_InscrireListeAttente
    @PatientId       INT,
    @EtablissementId INT,
    @SpecialiteId    INT,
    @Ville           NVARCHAR(80),
    @Region          NVARCHAR(80),
    @Priorite        TINYINT = 0,
    @SaisiPar        INT = NULL,
    @ListeAttenteId  INT = NULL OUTPUT,
    @Resultat        INT = NULL OUTPUT,
    @Message         NVARCHAR(200) = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @Max INT, @Auteur INT;
    SET @ListeAttenteId = NULL;

    SELECT @Max = e.MaxInscriptionsActives
    FROM dbo.Etablissement AS e
    WHERE e.Id = @EtablissementId AND e.EstArchive = 0;

    IF @Max IS NULL
    BEGIN SET @Resultat = -1; SET @Message = N'Etablissement introuvable ou archive.'; RETURN; END

    IF NOT EXISTS (SELECT 1 FROM dbo.Utilisateur WHERE Id = @PatientId AND Role = 'Patient' AND EstActif = 1 AND EstSuspendu = 0)
    BEGIN SET @Resultat = -4; SET @Message = N'Patient inconnu, inactif ou suspendu.'; RETURN; END

    -- La limite s'applique par etablissement (regle propre a chaque etablissement)
    IF (SELECT COUNT(*) FROM dbo.ListeAttente
        WHERE PatientId = @PatientId AND EtablissementId = @EtablissementId AND Statut = 'Active') >= @Max
    BEGIN SET @Resultat = -6; SET @Message = N'Limite d''inscriptions actives atteinte.'; RETURN; END

    IF EXISTS (SELECT 1 FROM dbo.ListeAttente
               WHERE PatientId = @PatientId AND EtablissementId = @EtablissementId
                 AND SpecialiteId = @SpecialiteId AND Statut = 'Active')
    BEGIN SET @Resultat = -7; SET @Message = N'Deja inscrit pour cette specialite dans cet etablissement.'; RETURN; END

    INSERT INTO dbo.ListeAttente (PatientId, EtablissementId, SpecialiteId, Ville, Region, Priorite, PrioriteSaisiePar)
    VALUES (@PatientId, @EtablissementId, @SpecialiteId, @Ville, @Region, @Priorite, @SaisiPar);
    SET @ListeAttenteId = SCOPE_IDENTITY();

    -- (un EXEC n'accepte pas d'expression comme valeur de parametre : on calcule d'abord dans une variable)
    SET @Auteur = ISNULL(@SaisiPar, @PatientId);
    EXEC dbo.usp_EnregistrerAudit @UtilisateurId = @Auteur, @Action = 'Creation', @Entite = 'ListeAttente',
         @EntiteId = @ListeAttenteId, @EtablissementId = @EtablissementId;
    SET @Resultat = 0; SET @Message = N'Inscription enregistree. Ajoutez au moins une disponibilite.';
END
GO

/* ---------- Reservation directe d'un creneau ---------- */
CREATE OR ALTER PROCEDURE dbo.usp_ReserverCreneau
    @CreneauId     INT,
    @PatientId     INT,
    @ReservationId INT = NULL OUTPUT,
    @Resultat      INT = NULL OUTPUT,
    @Message       NVARCHAR(200) = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @Own BIT = IIF(@@TRANCOUNT = 0, 1, 0);
    DECLARE @Now DATETIME2(0) = SYSUTCDATETIME();
    DECLARE @Statut VARCHAR(15), @Debut DATETIME2(0), @Etab INT;
    SET @ReservationId = NULL;

    IF @Own = 1 BEGIN TRANSACTION;
    BEGIN TRY
        SELECT @Statut = c.Statut, @Debut = c.DebutUtc, @Etab = p.EtablissementId
        FROM dbo.Creneau AS c WITH (UPDLOCK, HOLDLOCK)
        JOIN dbo.Praticien AS p ON p.Id = c.PraticienId
        WHERE c.Id = @CreneauId;

        IF @Statut IS NULL
        BEGIN SET @Resultat = -1; SET @Message = N'Creneau introuvable.'; END
        ELSE IF NOT EXISTS (SELECT 1 FROM dbo.Utilisateur WHERE Id = @PatientId AND Role = 'Patient' AND EstActif = 1 AND EstSuspendu = 0)
        BEGIN SET @Resultat = -4; SET @Message = N'Patient inconnu, inactif ou suspendu.'; END
        ELSE IF @Statut NOT IN ('Libre', 'DerniereMinute')
        BEGIN SET @Resultat = -2; SET @Message = N'Ce creneau n''est plus disponible.'; END
        ELSE IF @Debut <= @Now
        BEGIN SET @Resultat = -5; SET @Message = N'Ce creneau est passe.'; END
        ELSE
        BEGIN
            INSERT INTO dbo.Reservation (CreneauId, PatientId, DateDemandeUtc, DateReservationUtc, Origine)
            VALUES (@CreneauId, @PatientId, @Now, @Now, 'Directe');
            SET @ReservationId = SCOPE_IDENTITY();
            UPDATE dbo.Creneau SET Statut = 'Reserve', DateStatutUtc = @Now WHERE Id = @CreneauId;
            EXEC dbo.usp_EnregistrerAudit @UtilisateurId = @PatientId, @Action = 'Creation', @Entite = 'Reservation',
                 @EntiteId = @ReservationId, @EtablissementId = @Etab;
            SET @Resultat = 0; SET @Message = N'Reservation confirmee.';
        END

        IF @Own = 1 COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @Own = 1 AND @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

/* ---------- Annulation d'une reservation : le creneau passe en "derniere minute" et est propose au suivant ---------- */
CREATE OR ALTER PROCEDURE dbo.usp_AnnulerReservation
    @ReservationId INT,
    @UtilisateurId INT,
    @OffreId       INT = NULL OUTPUT,
    @Resultat      INT = NULL OUTPUT,
    @Message       NVARCHAR(200) = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @Own BIT = IIF(@@TRANCOUNT = 0, 1, 0);
    DECLARE @Now DATETIME2(0) = SYSUTCDATETIME();
    DECLARE @CreneauId INT, @Statut VARCHAR(10), @Etab INT;
    SET @OffreId = NULL;

    IF @Own = 1 BEGIN TRANSACTION;
    BEGIN TRY
        SELECT @CreneauId = r.CreneauId, @Statut = r.Statut, @Etab = p.EtablissementId
        FROM dbo.Reservation AS r WITH (UPDLOCK, HOLDLOCK)
        JOIN dbo.Creneau AS c ON c.Id = r.CreneauId
        JOIN dbo.Praticien AS p ON p.Id = c.PraticienId
        WHERE r.Id = @ReservationId;

        IF @CreneauId IS NULL
        BEGIN SET @Resultat = -1; SET @Message = N'Reservation introuvable.'; END
        ELSE IF @Statut <> 'Active'
        BEGIN SET @Resultat = -2; SET @Message = N'Reservation deja annulee.'; END
        ELSE
        BEGIN
            UPDATE dbo.Reservation
               SET Statut = 'Annulee', DateAnnulationUtc = @Now, AnnuleePar = @UtilisateurId
             WHERE Id = @ReservationId;

            UPDATE dbo.Creneau
               SET Statut = CASE WHEN DebutUtc <= @Now THEN 'Termine' ELSE 'DerniereMinute' END,
                   DateStatutUtc = @Now
             WHERE Id = @CreneauId;

            EXEC dbo.usp_EnregistrerAudit @UtilisateurId = @UtilisateurId, @Action = 'Modification', @Entite = 'Reservation',
                 @EntiteId = @ReservationId, @Detail = N'Annulation', @EtablissementId = @Etab;

            -- Cascade : proposition au meilleur candidat (le patient qui annule est exclu par la procedure)
            EXEC dbo.usp_ProposerCreneau @CreneauId = @CreneauId, @OffreId = @OffreId OUTPUT;

            SET @Resultat = CASE WHEN @OffreId IS NULL THEN 1 ELSE 0 END;
            SET @Message = CASE WHEN @OffreId IS NULL THEN N'Annulee. Aucun candidat : le creneau reste reservable.'
                                ELSE N'Annulee. Creneau propose au patient suivant.' END;
        END

        IF @Own = 1 COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @Own = 1 AND @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

/* ---------- Acceptation d'une offre ----------
   Deux acceptations simultanees : le verrou UPDLOCK/HOLDLOCK sur la ligne Offre les serialise,
   la seconde voit l'offre deja traitee (code -2). Une offre expiree est refusee meme si le clic est tardif. */
CREATE OR ALTER PROCEDURE dbo.usp_AccepterOffre
    @OffreId   INT,
    @PatientId INT,
    @Resultat  INT = NULL OUTPUT,
    @Message   NVARCHAR(200) = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @Own BIT = IIF(@@TRANCOUNT = 0, 1, 0);
    DECLARE @Now DATETIME2(0) = SYSUTCDATETIME();
    DECLARE @Statut VARCHAR(10), @Exp DATETIME2(0), @CreneauId INT, @LaId INT, @Pat INT, @Suivant INT, @Etab INT;

    IF @Own = 1 BEGIN TRANSACTION;
    BEGIN TRY
        SELECT @Statut = o.Statut, @Exp = o.DateExpirationUtc, @CreneauId = o.CreneauId,
               @LaId = o.ListeAttenteId, @Pat = o.PatientId, @Etab = p.EtablissementId
        FROM dbo.Offre AS o WITH (UPDLOCK, HOLDLOCK)
        JOIN dbo.Creneau AS c ON c.Id = o.CreneauId
        JOIN dbo.Praticien AS p ON p.Id = c.PraticienId
        WHERE o.Id = @OffreId;

        IF @Statut IS NULL
        BEGIN SET @Resultat = -1; SET @Message = N'Offre introuvable.'; END
        ELSE IF @Pat <> @PatientId
        BEGIN SET @Resultat = -4; SET @Message = N'Cette offre ne vous est pas destinee.'; END
        ELSE IF @Statut <> 'EnAttente'
        BEGIN SET @Resultat = -2; SET @Message = N'Offre deja traitee ou expiree.'; END
        ELSE IF @Exp <= @Now
        BEGIN
            -- Offre expiree : on l'enregistre et on passe au candidat suivant
            UPDATE dbo.Offre SET Statut = 'Expiree', DateReponseUtc = @Now WHERE Id = @OffreId;
            UPDATE dbo.Creneau
               SET Statut = CASE WHEN DebutUtc <= @Now THEN 'Termine' ELSE 'DerniereMinute' END, DateStatutUtc = @Now
             WHERE Id = @CreneauId AND Statut = 'Propose';
            EXEC dbo.usp_ProposerCreneau @CreneauId = @CreneauId, @OffreId = @Suivant OUTPUT;
            SET @Resultat = -3; SET @Message = N'Offre expiree.';
        END
        ELSE
        BEGIN
            UPDATE dbo.Offre SET Statut = 'Acceptee', DateReponseUtc = @Now WHERE Id = @OffreId;
            UPDATE dbo.Creneau SET Statut = 'Reserve', DateStatutUtc = @Now WHERE Id = @CreneauId;

            INSERT INTO dbo.Reservation (CreneauId, PatientId, DateDemandeUtc, DateReservationUtc, Origine)
            SELECT @CreneauId, @PatientId, la.DateInscriptionUtc, @Now, 'ListeAttente'
            FROM dbo.ListeAttente AS la WHERE la.Id = @LaId;

            UPDATE dbo.ListeAttente SET Statut = 'Satisfaite', DateFinUtc = @Now WHERE Id = @LaId;

            EXEC dbo.usp_EnregistrerAudit @UtilisateurId = @PatientId, @Action = 'Modification', @Entite = 'Offre',
                 @EntiteId = @OffreId, @Detail = N'Offre acceptee', @EtablissementId = @Etab;
            SET @Resultat = 0; SET @Message = N'Rendez-vous confirme.';
        END

        IF @Own = 1 COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @Own = 1 AND @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

/* ---------- Refus d'une offre : passage au suivant ---------- */
CREATE OR ALTER PROCEDURE dbo.usp_RefuserOffre
    @OffreId         INT,
    @PatientId       INT,
    @OffreSuivanteId INT = NULL OUTPUT,
    @Resultat        INT = NULL OUTPUT,
    @Message         NVARCHAR(200) = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @Own BIT = IIF(@@TRANCOUNT = 0, 1, 0);
    DECLARE @Now DATETIME2(0) = SYSUTCDATETIME();
    DECLARE @Statut VARCHAR(10), @CreneauId INT, @Pat INT, @Etab INT;
    SET @OffreSuivanteId = NULL;

    IF @Own = 1 BEGIN TRANSACTION;
    BEGIN TRY
        SELECT @Statut = o.Statut, @CreneauId = o.CreneauId, @Pat = o.PatientId, @Etab = p.EtablissementId
        FROM dbo.Offre AS o WITH (UPDLOCK, HOLDLOCK)
        JOIN dbo.Creneau AS c ON c.Id = o.CreneauId
        JOIN dbo.Praticien AS p ON p.Id = c.PraticienId
        WHERE o.Id = @OffreId;

        IF @Statut IS NULL
        BEGIN SET @Resultat = -1; SET @Message = N'Offre introuvable.'; END
        ELSE IF @Pat <> @PatientId
        BEGIN SET @Resultat = -4; SET @Message = N'Cette offre ne vous est pas destinee.'; END
        ELSE IF @Statut <> 'EnAttente'
        BEGIN SET @Resultat = -2; SET @Message = N'Offre deja traitee ou expiree.'; END
        ELSE
        BEGIN
            UPDATE dbo.Offre SET Statut = 'Refusee', DateReponseUtc = @Now WHERE Id = @OffreId;
            UPDATE dbo.Creneau
               SET Statut = CASE WHEN DebutUtc <= @Now THEN 'Termine' ELSE 'DerniereMinute' END, DateStatutUtc = @Now
             WHERE Id = @CreneauId AND Statut = 'Propose';

            EXEC dbo.usp_EnregistrerAudit @UtilisateurId = @PatientId, @Action = 'Modification', @Entite = 'Offre',
                 @EntiteId = @OffreId, @Detail = N'Offre refusee', @EtablissementId = @Etab;

            EXEC dbo.usp_ProposerCreneau @CreneauId = @CreneauId, @OffreId = @OffreSuivanteId OUTPUT;
            SET @Resultat = 0; SET @Message = N'Offre refusee. Vous restez sur la liste d''attente.';
        END

        IF @Own = 1 COMMIT TRANSACTION;
    END TRY
    BEGIN CATCH
        IF @Own = 1 AND @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
        THROW;
    END CATCH
END
GO

/* ---------- Expiration des offres : appelee periodiquement par le BackgroundService (pas de SQL Server Agent) ----------
   Traite les offres de TOUS les etablissements ; chaque cascade utilise les regles de l'etablissement du creneau. */
CREATE OR ALTER PROCEDURE dbo.usp_ExpirerOffres
    @NbExpirees INT = NULL OUTPUT
AS
BEGIN
    SET NOCOUNT ON;
    SET XACT_ABORT ON;
    DECLARE @Id INT, @CreneauId INT, @Now DATETIME2(0), @Suivant INT;
    SET @NbExpirees = 0;

    WHILE 1 = 1
    BEGIN
        SET @Id = NULL;
        SET @Now = SYSUTCDATETIME();

        SELECT TOP (1) @Id = o.Id, @CreneauId = o.CreneauId
        FROM dbo.Offre AS o
        WHERE o.Statut = 'EnAttente' AND o.DateExpirationUtc <= @Now
        ORDER BY o.DateExpirationUtc;

        IF @Id IS NULL BREAK;

        BEGIN TRY
            BEGIN TRANSACTION;

            UPDATE dbo.Offre SET Statut = 'Expiree', DateReponseUtc = @Now
             WHERE Id = @Id AND Statut = 'EnAttente';

            IF @@ROWCOUNT = 1
            BEGIN
                UPDATE dbo.Creneau
                   SET Statut = CASE WHEN DebutUtc <= @Now THEN 'Termine' ELSE 'DerniereMinute' END, DateStatutUtc = @Now
                 WHERE Id = @CreneauId AND Statut = 'Propose';
                EXEC dbo.usp_ProposerCreneau @CreneauId = @CreneauId, @OffreId = @Suivant OUTPUT;
                SET @NbExpirees = @NbExpirees + 1;
            END

            COMMIT TRANSACTION;
        END TRY
        BEGIN CATCH
            IF @@TRANCOUNT > 0 ROLLBACK TRANSACTION;
            THROW;
        END CATCH
    END
END
GO

PRINT 'Procedures CareFlow creees.';
GO
