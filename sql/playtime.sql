-- Playtime database structure
DROP DATABASE IF EXISTS playtime;
CREATE DATABASE playtime;
USE playtime;

CREATE TABLE pt_servers
(
  ServerID int NOT NULL AUTO_INCREMENT,
  ServerName varchar(32) NOT NULL,
  PRIMARY KEY (ServerID)
);

CREATE TABLE pt_times
(
  authid varchar(32) NOT NULL,
  name varchar(64) NOT NULL,
  ServerID int NOT NULL,
  playtime_ct int DEFAULT 0,
  playtime_t int DEFAULT 0,
  CONSTRAINT pk_authserver PRIMARY KEY (authid,ServerID),
  FOREIGN KEY (ServerID) REFERENCES pt_servers(ServerID)
);