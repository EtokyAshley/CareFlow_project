/* =====================================================================
   CareFlow - 05_scenario_test.sql
   Scenario de test de la cascade. A lancer APRES 04_donnees_test.sql,
   en UNE SEULE execution. Verifie les criteres d'acceptation du cahier des charges.

   Resultats attendus :
   Etape 1  reservation du patient 1                 -> Resultat 0, creneau Reserve
   Etape 2  annulation par le patient 1              -> offre pour le patient 2 (score 46),
                                                        PAS pour le patient 1 (annulation) ni le 4 (hors dispo)
   Etape 3  le patient 2 refuse                      -> offre pour le patient 3 (score 40)
   Etape 4  le patient 3 accepte                     -> Resultat 0, creneau Reserve
   Etape 5  le patient 3 re-accepte la meme offre    -> Resultat -2 (deja traitee)
   Etape 6  annulation sans candidat                 -> Resultat 1, creneau reste reservable
   ===================================================================== */
SET NOCOUNT ON;

DECLARE @P1 INT = (SELECT Id FROM dbo.Utilisateur WHERE Email = N'patient1@test.local');
DECLARE @P2 INT = (SELECT Id FROM dbo.Utilisateur WHERE Email = N'patient2@test.local');
DECLARE @P3 INT = (SELECT Id FROM dbo.Utilisateur WHERE Email = N'patient3@test.local');
DECLARE @C  INT = (SELECT TOP (1) Id FROM dbo.Creneau WHERE Statut = 'Libre' ORDER BY DebutUtc);
DECLARE @Res INT, @Msg NVARCHAR(200), @ResaId INT, @Offre1 INT, @Offre2 INT, @Offre3 INT;

-- Etape 1 : le patient 1 reserve
EXEC dbo.usp_ReserverCreneau @CreneauId = @C, @PatientId = @P1, @ReservationId = @ResaId OUTPUT, @Resultat = @Res OUTPUT, @Message = @Msg OUTPUT;
SELECT N'Etape 1 - reservation' AS Etape, @Res AS Resultat, @Msg AS Message, (SELECT Statut FROM dbo.Creneau WHERE Id = @C) AS StatutCreneau;

-- Etape 2 : le patient 1 annule -> offre automatique
EXEC dbo.usp_AnnulerReservation @ReservationId = @ResaId, @UtilisateurId = @P1, @OffreId = @Offre1 OUTPUT, @Resultat = @Res OUTPUT, @Message = @Msg OUTPUT;
SELECT N'Etape 2 - annulation' AS Etape, @Res AS Resultat, @Msg AS Message, (SELECT Statut FROM dbo.Creneau WHERE Id = @C) AS StatutCreneau,
       o.Id AS OffreId, u.Nom AS PropositionPour, o.Score, o.DateExpirationUtc
FROM dbo.Offre AS o JOIN dbo.Utilisateur AS u ON u.Id = o.PatientId WHERE o.Id = @Offre1;

-- Etape 3 : le patient 2 refuse -> offre au patient 3
EXEC dbo.usp_RefuserOffre @OffreId = @Offre1, @PatientId = @P2, @OffreSuivanteId = @Offre2 OUTPUT, @Resultat = @Res OUTPUT, @Message = @Msg OUTPUT;
SELECT N'Etape 3 - refus' AS Etape, @Res AS Resultat, @Msg AS Message,
       o.Id AS OffreId, u.Nom AS PropositionPour, o.Score
FROM dbo.Offre AS o JOIN dbo.Utilisateur AS u ON u.Id = o.PatientId WHERE o.Id = @Offre2;

-- Etape 4 : le patient 3 accepte
EXEC dbo.usp_AccepterOffre @OffreId = @Offre2, @PatientId = @P3, @Resultat = @Res OUTPUT, @Message = @Msg OUTPUT;
SELECT N'Etape 4 - acceptation' AS Etape, @Res AS Resultat, @Msg AS Message, (SELECT Statut FROM dbo.Creneau WHERE Id = @C) AS StatutCreneau;

-- Etape 5 : double acceptation de la meme offre
EXEC dbo.usp_AccepterOffre @OffreId = @Offre2, @PatientId = @P3, @Resultat = @Res OUTPUT, @Message = @Msg OUTPUT;
SELECT N'Etape 5 - double acceptation' AS Etape, @Res AS Resultat, @Msg AS Message;

-- Etape 6 : annulation d'un creneau sans candidat (la liste du 2eme creneau n'a plus de candidat eligible
--           apres epuisement : on reserve puis on annule avec le patient 3 deja satisfait)
DECLARE @C2 INT = (SELECT TOP (1) Id FROM dbo.Creneau WHERE Statut = 'Libre' ORDER BY DebutUtc);
DECLARE @Resa2 INT, @Offre4 INT;
-- on retire d'abord les candidats restants pour simuler "aucun candidat"
UPDATE dbo.ListeAttente SET Statut = 'Annulee', DateFinUtc = SYSUTCDATETIME() WHERE Statut = 'Active';
EXEC dbo.usp_ReserverCreneau @CreneauId = @C2, @PatientId = @P3, @ReservationId = @Resa2 OUTPUT, @Resultat = @Res OUTPUT, @Message = @Msg OUTPUT;
EXEC dbo.usp_AnnulerReservation @ReservationId = @Resa2, @UtilisateurId = @P3, @OffreId = @Offre4 OUTPUT, @Resultat = @Res OUTPUT, @Message = @Msg OUTPUT;
SELECT N'Etape 6 - annulation sans candidat' AS Etape, @Res AS Resultat, @Msg AS Message, (SELECT Statut FROM dbo.Creneau WHERE Id = @C2) AS StatutCreneau;

-- Bilan
SELECT N'Offres' AS Table_, o.Id, u.Nom AS Patient, o.Score, o.Statut FROM dbo.Offre AS o JOIN dbo.Utilisateur AS u ON u.Id = o.PatientId ORDER BY o.Id;
SELECT N'Notifications' AS Table_, n.Id, u.Nom AS Patient, n.Message FROM dbo.Notification AS n JOIN dbo.Utilisateur AS u ON u.Id = n.UtilisateurId ORDER BY n.Id;
SELECT N'Audit' AS Table_, a.Id, a.Action, a.Entite, a.EntiteId, a.Detail FROM dbo.JournalAudit AS a ORDER BY a.Id;
SELECT * FROM dbo.vw_CreneauxRecuperes;
SELECT * FROM dbo.vw_DelaiPremierRdv;

-- Test du journal en ajout seul (doit ECHOUER avec l'erreur 50001) :
--   UPDATE dbo.JournalAudit SET Detail = N'x';
--   DELETE FROM dbo.JournalAudit;
