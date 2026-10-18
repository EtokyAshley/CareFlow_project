/* =====================================================================
   CareFlow - 00_reset_dev.sql  (version 2 : etablissement unique)
   ATTENTION : supprime TOUT le schema CareFlow (tables, procedures, vues).
   Pour le DEVELOPPEMENT uniquement. Ne jamais lancer sur une base avec des
   donnees a conserver. Prevenir l'equipe avant de l'executer.
   Supprime aussi dbo.Etablissement si l'ANCIENNE version (multi-etablissements)
   avait ete installee.
   ===================================================================== */
SET NOCOUNT ON;
GO
DROP VIEW IF EXISTS dbo.vw_DelaiPremierRdv;
DROP VIEW IF EXISTS dbo.vw_CreneauxRecuperes;
DROP VIEW IF EXISTS dbo.vw_TauxOccupation;
GO
DROP PROCEDURE IF EXISTS dbo.usp_ExpirerOffres;
DROP PROCEDURE IF EXISTS dbo.usp_RefuserOffre;
DROP PROCEDURE IF EXISTS dbo.usp_AccepterOffre;
DROP PROCEDURE IF EXISTS dbo.usp_AnnulerReservation;
DROP PROCEDURE IF EXISTS dbo.usp_ReserverCreneau;
DROP PROCEDURE IF EXISTS dbo.usp_InscrireListeAttente;
DROP PROCEDURE IF EXISTS dbo.usp_ProposerCreneau;
DROP PROCEDURE IF EXISTS dbo.usp_EnregistrerAudit;
GO
DROP TABLE IF EXISTS dbo.JournalAudit;
DROP TABLE IF EXISTS dbo.MessageUrgence;
DROP TABLE IF EXISTS dbo.NumeroUrgence;
DROP TABLE IF EXISTS dbo.ReponseOrientation;
DROP TABLE IF EXISTS dbo.QuestionOrientation;
DROP TABLE IF EXISTS dbo.CapsuleInformation;
DROP TABLE IF EXISTS dbo.Notification;
DROP TABLE IF EXISTS dbo.Offre;
DROP TABLE IF EXISTS dbo.DisponibiliteAttente;
DROP TABLE IF EXISTS dbo.ListeAttente;
DROP TABLE IF EXISTS dbo.Reservation;
DROP TABLE IF EXISTS dbo.Creneau;
DROP TABLE IF EXISTS dbo.Utilisateur;
DROP TABLE IF EXISTS dbo.Praticien;
DROP TABLE IF EXISTS dbo.Specialite;
DROP TABLE IF EXISTS dbo.ParametreEtablissement;
DROP TABLE IF EXISTS dbo.Etablissement;   -- ancienne version uniquement
GO
PRINT 'Schema CareFlow supprime.';
GO
