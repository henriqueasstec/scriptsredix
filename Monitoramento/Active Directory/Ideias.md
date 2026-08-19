# Monitoramento Controlador de Domínio - Security Line Base Redix

Documento consiste em documentar ideias que surgem para alertas em controlador de domínio, "projeto" que está sendo implementado com objetivo de monitorar coisas essenciais para segurança em um ambiente de Active Directory.

* Contas de usuários não são mais utilizados a X dias
* Contas de usuários e administrador que não trocam a senha X dias
* Windows Defender Credential Guard desabilitado nos controladores de domínio.
    * OBS: Windows Server 2016+
* Bitlocker desabilitado 
* Logs de auditoria:
    * 1 evento 1 alerta:
        * 4719 — política de auditoria alterada
        * 1102 — log de auditoria limpo
        * 4765 — SID History adicionado
        * 4766 — tentativa de adicionar SID History falhou
        * 4794 — tentativa de definir DSRM
        * 4780 — ACL definida em contas que são membros de grupos administrativos
        * 4728 / 4729 / 4732 / 4733 / 4756 / 4757— adição ou remoção de membros em grupos de segurança privilegiados. Monitorar com match com: 
            * Domain Admins
            * Enterprise Admins
            * Schema Admins
            * Administrators
            * Account Operators
            * Backup Operators
            * Server Operators
    * X quantidade em X tempo:
        * 4771 — falha na pré-autenticação Kerberos
        * 4777 — falha na validação de credenciais NTLM
        * Verificar motivo — conta de usuário bloqueada
* Patches de segurança sem aplicar nos últimos X dias
    * OBS: Talvez enquadre um monitoramento incluso no padrão dos servidores Windows
* SMB 1.0 habilitado
* SMB Signing não exigido
* LDAP signing não exigido
* LDAP Channel binding não exigido
* Contas privilegiadas fora de Protected Users
* X contas em grupos administrativos 
* NTDM habilitado
* LSASS / LSA protection desabilitada
* Contas com Kerberos preauthentication desabilitada
* krbgt redefinir a senha após coleta de informações do ataque


* Patches de segurança sem aplicar nos últimos X dias