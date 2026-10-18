/* =====================================================================
   CareFlow - 03_vues.sql  (version 2 : UN SEUL etablissement)
   Vues du tableau de bord (F8). Chaque vue renvoie une seule ligne.
   Fichier volontairement sans accents (compatibilite SSMS).
   ===================================================================== */
SET QUOTED_IDENTIFIER ON;
SET ANSI_NULLS ON;
GO

/* Taux d'occupation (creneaux non annules) */
CREATE OR ALTER VIEW dbo.vw_TauxOccupation
AS
SELECT  COUNT(*) AS NbCreneaux,
        SUM(CASE WHEN c.Statut = 'Reserve' THEN 1 ELSE 0 END) AS NbReserves,
        CAST(100.0 * SUM(CASE WHEN c.Statut = 'Reserve' THEN 1 ELSE 0 END) / NULLIF(COUNT(*), 0) AS DECIMAL(5,1)) AS TauxOccupationPourcent
FROM dbo.Creneau AS c
WHERE c.Statut <> 'Annule';
GO

/* Creneaux liberes (annulations) et recuperes (de nouveau reserves) */
CREATE OR ALTER VIEW dbo.vw_CreneauxRecuperes
AS
SELECT  COUNT(DISTINCT c.Id) AS CreneauxLiberes,
        COUNT(DISTINCT CASE WHEN ra.Id IS NOT NULL THEN c.Id END) AS CreneauxRecuperes,
        CAST(100.0 * COUNT(DISTINCT CASE WHEN ra.Id IS NOT NULL THEN c.Id END) / NULLIF(COUNT(DISTINCT c.Id), 0) AS DECIMAL(5,1)) AS TauxRecuperationPourcent
FROM dbo.Creneau AS c
JOIN dbo.Reservation AS rc ON rc.CreneauId = c.Id AND rc.Statut = 'Annulee'
LEFT JOIN dbo.Reservation AS ra ON ra.CreneauId = c.Id AND ra.Statut = 'Active';
GO

/* Indicateur principal : delai moyen (en jours) entre la demande et le PREMIER rendez-vous du patient */
CREATE OR ALTER VIEW dbo.vw_DelaiPremierRdv
AS
WITH premiers AS (
    SELECT  r.PatientId, r.DateDemandeUtc, c.DebutUtc,
            ROW_NUMBER() OVER (PARTITION BY r.PatientId ORDER BY c.DebutUtc) AS Rang
    FROM dbo.Reservation AS r
    JOIN dbo.Creneau AS c ON c.Id = r.CreneauId
    WHERE r.Statut = 'Active'
)
SELECT  COUNT(*) AS NbPatients,
        CAST(AVG(CAST(DATEDIFF(MINUTE, DateDemandeUtc, DebutUtc) AS FLOAT)) / 1440.0 AS DECIMAL(10,2)) AS DelaiMoyenJours
FROM premiers
WHERE Rang = 1;
GO

PRINT 'Vues CareFlow creees.';
GO
