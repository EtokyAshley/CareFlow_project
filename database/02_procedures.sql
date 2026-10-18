/* =====================================================================
   CareFlow - 02_procedures.sql  (version 2 : UN SEUL etablissement)
   Procedures stockees de la liste d'attente.

   Transactions : chaque procedure ouvre sa propre transaction SEULEMENT si
   aucune n'est deja ouverte. Cote C#, on peut donc ouvrir une SqlTransaction
   ADO.NET et y executer plusieurs procedures : tout sera valide ou annule ensemble.

   Codes @Resultat :  0 = succes
                      1 = succes sans offre (aucun candidat, le creneau reste reservable)
                     -1 = introuvable   -2 = deja traite / indisponible
                     -3 = offre expiree -4 = acces refuse   -5 = trop tard
                     -6 = limite d'inscriptions atteinte    -7 = deja inscrit
   Les parametres (poids, delais, ville) sont lus dans ParametreEtablissement (Id = 1).
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
    @AdresseIp       VARCHAR(45) = NULL
AS
BEGIN
    SET NOCOUNT ON;
    INSERT INTO dbo.JournalAudit (UtilisateurId, Action, Entite, EntiteId, Succes, Detail, AdresseIp)
    VALUES (@UtilisateurId, @Action, @Entite, @EntiteId, @Succes, @Detail, @AdresseIp);
END
GO

/* ---------- Proposer un creneau "derniere minute" au meilleur candidat ----------
   Classement : score = PoidsPriorite*Priorite + PoidsAnciennete*jours_attente + PoidsProximite*(ville=2, region=1)
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
    DECLARE @Spec INT, @Debut DATETIME2(0), @Fin DATETIME2(0), @Statut VARCHAR(15);
    DECLARE @wP DECIMAL(6,2) = 10, @wA DECIMAL(6,2) = 1, @wX DECIMAL(6,2) = 3;   -- valeurs par defaut si pas de parametres
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
        SELECT @Spec = p.SpecialiteId, @Debut = c.DebutUtc, @Fin = c.FinUtc, @Statut = c.Statut
        FROM dbo.Creneau AS c WITH (UPDLOCK, HOLDLOCK)
        JOIN dbo.Praticien AS p ON p.Id = c.PraticienId
        WHERE c.Id = @CreneauId;

        SELECT @wP = pe.PoidsPriorite, @wA = pe.PoidsAnciennete, @wX = pe.PoidsProximite,
               @Delai = pe.DelaiAcceptationMinutes, @DelaiMin = pe.DelaiMinAvantCreneauMinutes,
               @Decal = pe.DecalageUtcMinutes, @VilleE = pe.Ville, @RegionE = pe.Region
        FROM dbo.ParametreEtablissement AS pe
        WHERE pe.Id = 1;

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
                     @EntiteId = @OffreId, @Detail = N'Offre proposee automatiquement';
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

/* ---------- Inscription a la liste d'attente ---------- */
CREATE OR ALTER PROCEDURE dbo.usp_InscrireListeAttente
    @PatientId       INT,
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
    DECLARE @Max INT = 3;
    SET @ListeAttenteId = NULL;

    SELECT @Max = pe.MaxInscriptionsActives FROM dbo.ParametreEtablissement AS pe WHERE pe.Id = 1;

    IF NOT EXISTS (SELECT 1 FROM dbo.Utilisateur WHERE Id = @PatientId AND Role = 'Patient' AND EstActif = 1 AND EstSuspendu = 0)
    BEGIN SET @Resultat = -4; SET @Message = N'Patient inconnu, inactif ou suspendu.'; RETURN; END

    IF (SELECT COUNT(*) FROM dbo.ListeAttente WHERE PatientId = @PatientId AND Statut = 'Active') >= @Max
    BEGIN SET @Resultat = -6; SET @Message = N'Limite d''inscriptions actives atteinte.'; RETURN; END

    IF EXISTS (SELECT 1 FROM dbo.ListeAttente
               WHERE PatientId = @PatientId AND SpecialiteId = @SpecialiteId AND Statut = 'Active')
    BEGIN SET @Resultat = -7; SET @Message = N'Deja inscrit pour cette specialite.'; RETURN; END

    INSERT INTO dbo.ListeAttente (PatientId, SpecialiteId, Ville, Region, Priorite, PrioriteSaisiePar)
    VALUES (@PatientId, @SpecialiteId, @Ville, @Region, @Priorite, @SaisiPar);
    SET @ListeAttenteId = SCOPE_IDENTITY();

    EXEC dbo.usp_EnregistrerAudit @UtilisateurId = @SaisiPar, @Action = 'Creation', @Entite = 'ListeAttente',
         @EntiteId = @ListeAttenteId;
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
    DECLARE @Statut VARCHAR(15), @Debut DATETIME2(0);
    SET @ReservationId = NULL;

    IF @Own = 1 BEGIN TRANSACTION;
    BEGIN TRY
        SELECT @Statut = c.Statut, @Debut = c.DebutUtc
        FROM dbo.Creneau AS c WITH (UPDLOCK, HOLDLOCK)
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
                 @EntiteId = @ReservationId;
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
    DECLARE @CreneauId INT, @Statut VARCHAR(10);
    SET @OffreId = NULL;

    IF @Own = 1 BEGIN TRANSACTION;
    BEGIN TRY
        SELECT @CreneauId = r.CreneauId, @Statut = r.Statut
        FROM dbo.Reservation AS r WITH (UPDLOCK, HOLDLOCK)
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
                 @EntiteId = @ReservationId, @Detail = N'Annulation';

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
    DECLARE @Statut VARCHAR(10), @Exp DATETIME2(0), @CreneauId INT, @LaId INT, @Pat INT, @Suivant INT;

    IF @Own = 1 BEGIN TRANSACTION;
    BEGIN TRY
        SELECT @Statut = o.Statut, @Exp = o.DateExpirationUtc, @CreneauId = o.CreneauId,
               @LaId = o.ListeAttenteId, @Pat = o.PatientId
        FROM dbo.Offre AS o WITH (UPDLOCK, HOLDLOCK)
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
                 @EntiteId = @OffreId, @Detail = N'Offre acceptee';
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
    DECLARE @Statut VARCHAR(10), @CreneauId INT, @Pat INT;
    SET @OffreSuivanteId = NULL;

    IF @Own = 1 BEGIN TRANSACTION;
    BEGIN TRY
        SELECT @Statut = o.Statut, @CreneauId = o.CreneauId, @Pat = o.PatientId
        FROM dbo.Offre AS o WITH (UPDLOCK, HOLDLOCK)
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
                 @EntiteId = @OffreId, @Detail = N'Offre refusee';

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

/* ---------- Expiration des offres : appelee periodiquement par le BackgroundService (pas de SQL Server Agent) ---------- */
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
