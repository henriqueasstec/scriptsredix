Import-Module ActiveDirectory

[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ============================================================
# CONFIGURAÇÕES
# ============================================================

$SmtpServer = "smtp.office365.com"
$SmtpPort   = 587

# Conta que vai enviar os e-mails
$SmtpUser = "enviar@redix.com.br"

# Senha da conta de envio
$SmtpPassword = @'
1QER2Kn4GC6fR5c@
'@

# Remetente
$From = $SmtpUser

# Dias em que o e-mail será enviado
$ThresholdDays = @(14, 7, 3, 1)

# Deixe vazio para buscar no domínio todo
# Exemplo:
# $SearchBase = "OU=Usuarios,DC=redix,DC=local"
$SearchBase = ""

$Today = (Get-Date).Date

# ============================================================
# FUNÇÃO PARA CALCULAR DATA DE EXPIRAÇÃO
# ============================================================

function Get-PasswordExpiryDate {
    param(
        [Parameter(Mandatory = $true)]
        $User
    )

    if ($User.PasswordNeverExpires -eq $true) {
        return $null
    }

    $RawExpiry = $User."msDS-UserPasswordExpiryTimeComputed"

    if ($null -eq $RawExpiry) {
        return $null
    }

    if ($RawExpiry -eq 0) {
        return $null
    }

    if ($RawExpiry -eq 9223372036854775807) {
        return $null
    }

    try {
        return [datetime]::FromFileTime([int64]$RawExpiry)
    }
    catch {
        return $null
    }
}

# ============================================================
# FUNÇÃO PARA GERAR HTML DO E-MAIL
# ============================================================

function Get-PasswordExpiryHtml {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,

        [Parameter(Mandatory = $true)]
        [int]$DaysLeft,

        [Parameter(Mandatory = $true)]
        [datetime]$ExpiryDate
    )

    $SafeName = [System.Net.WebUtility]::HtmlEncode($Name)
    $ExpiryDateText = $ExpiryDate.ToString("dd/MM/yyyy")

    $Html = @"
<!DOCTYPE html>
<html lang="pt-BR">
<head>
    <meta charset="UTF-8">
    <title>Aviso de expiração de senha</title>
</head>

<body style="margin:0; padding:0; background-color:#f5f5f5; font-family:Arial, Helvetica, sans-serif; color:#1f1f1f;">

    <table width="100%" cellpadding="0" cellspacing="0" border="0" style="background-color:#f5f5f5; padding:32px 0;">
        <tr>
            <td align="center">

                <table width="600" cellpadding="0" cellspacing="0" border="0" style="width:600px; max-width:600px; background-color:#ffffff; border-collapse:collapse;">

                    <tr>
                        <td style="background-color:#e57f56; padding:28px 36px;">
                            <p style="margin:0; font-size:13px; line-height:1.4; color:#ffffff; letter-spacing:0.5px; text-transform:uppercase;">
                                Aviso de segurança
                            </p>

                            <h1 style="margin:8px 0 0 0; font-size:24px; line-height:1.3; font-weight:bold; color:#ffffff;">
                                Sua senha está prestes a expirar
                            </h1>
                        </td>
                    </tr>

                    <tr>
                        <td style="padding:36px 40px 28px 40px;">

                            <p style="margin:0 0 20px 0; font-size:16px; line-height:1.6; color:#1f1f1f;">
                                Olá, <strong>$SafeName</strong>,
                            </p>

                            <p style="margin:0 0 20px 0; font-size:16px; line-height:1.6; color:#1f1f1f;">
                                Sua senha de rede está prestes a expirar em 
                                <strong style="color:#e57f56;">$DaysLeft dia(s)</strong>, no dia <strong>$ExpiryDateText</strong>.
                            </p>

                            <p style="margin:0 0 24px 0; font-size:16px; line-height:1.6; color:#1f1f1f;">
                                Para evitar problemas de acesso aos sistemas corporativos, recomendamos que você altere sua senha antes do vencimento.
                            </p>

                            <table width="100%" cellpadding="0" cellspacing="0" border="0" style="background-color:#fff7f3; border-left:4px solid #e57f56; margin:0 0 28px 0;">
                                <tr>
                                    <td style="padding:16px 18px;">
                                        <p style="margin:0; font-size:15px; line-height:1.6; color:#1f1f1f;">
                                            <strong>Ação necessária:</strong><br>
                                            Escolha abaixo o cenário que se aplica ao seu equipamento e realize a troca da senha antes do vencimento.
                                        </p>
                                    </td>
                                </tr>
                            </table>

                            <p style="margin:0 0 12px 0; font-size:16px; line-height:1.6; color:#1f1f1f;">
                                <strong>Como alterar sua senha:</strong>
                            </p>

                            <table width="100%" cellpadding="0" cellspacing="0" border="0" style="border:1px solid #e5e5e5; margin:0 0 20px 0;">
                                <tr>
                                    <td style="padding:18px 20px;">
                                        <p style="margin:0 0 10px 0; font-size:15px; line-height:1.6; color:#1f1f1f;">
                                            <strong>Opção 1 — Computador corporativo no domínio</strong>
                                        </p>

                                        <ol style="margin:0 0 0 22px; padding:0; font-size:15px; line-height:1.8; color:#1f1f1f;">
                                            <li>Pressione <strong>Ctrl + Alt + Del</strong>.</li>
                                            <li>Selecione <strong>Alterar uma senha</strong>.</li>
                                            <li>Informe sua senha atual.</li>
                                            <li>Digite a nova senha e confirme.</li>
                                            <li>Aguarde a mensagem de confirmação da alteração.</li>
                                        </ol>
                                    </td>
                                </tr>
                            </table>

                            <table width="100%" cellpadding="0" cellspacing="0" border="0" style="border:1px solid #e5e5e5; margin:0 0 20px 0;">
                                <tr>
                                    <td style="padding:18px 20px;">
                                        <p style="margin:0 0 10px 0; font-size:15px; line-height:1.6; color:#1f1f1f;">
                                            <strong>Opção 2 — Equipamento fora do domínio ou acesso remoto</strong>
                                        </p>

                                        <p style="margin:0 0 12px 0; font-size:15px; line-height:1.6; color:#1f1f1f;">
                                            Se você utiliza um notebook fora do domínio, computador pessoal ou acessa apenas sistemas corporativos como e-mail, Microsoft 365, VPN ou portais internos, altere sua senha pelo portal da Microsoft.
                                        </p>

                                        <ol style="margin:0 0 16px 22px; padding:0; font-size:15px; line-height:1.8; color:#1f1f1f;">
                                            <li>Acesse o portal <strong>Minhas entradas</strong> pelo botão abaixo.</li>
                                            <li>Entre com seu e-mail corporativo, caso seja solicitado.</li>
                                            <li>Clique em <strong>Informações de segurança</strong>.</li>
                                            <li>Localize o campo <strong>Senha</strong> e clique em <strong>Alterar</strong>.</li>
                                            <li>Digite a nova senha.</li>
                                            <li>Repita a nova senha no campo de confirmação.</li>
                                            <li>Clique em <strong>Confirmar</strong> para concluir a alteração.</li>
                                        </ol>

                                        <table cellpadding="0" cellspacing="0" border="0" style="margin:0 0 14px 0;">
                                            <tr>
                                                <td style="background-color:#e57f56; padding:12px 18px;">
                                                    <a href="https://mysignins.microsoft.com/" style="font-size:15px; font-family:Arial, Helvetica, sans-serif; color:#ffffff; text-decoration:none; font-weight:bold;">
                                                        Acessar portal Minhas entradas
                                                    </a>
                                                </td>
                                            </tr>
                                        </table>

                                        <p style="margin:0; font-size:13px; line-height:1.6; color:#777777;">
                                            Após concluir a alteração, utilize a nova senha nos acessos corporativos.
                                        </p>
                                    </td>
                                </tr>
                            </table>

                            <table width="100%" cellpadding="0" cellspacing="0" border="0" style="background-color:#f8f8f8; border-left:4px solid #999999; margin:0 0 26px 0;">
                                <tr>
                                    <td style="padding:16px 18px;">
                                        <p style="margin:0 0 10px 0; font-size:15px; line-height:1.6; color:#1f1f1f;">
                                            <strong>Esqueceu a senha ou não consegue acessar?</strong>
                                        </p>

                                        <p style="margin:0 0 14px 0; font-size:15px; line-height:1.6; color:#1f1f1f;">
                                            Utilize a redefinição de senha pelo portal abaixo. Será necessário validar sua identidade com os métodos de segurança cadastrados.
                                        </p>

                                        <table cellpadding="0" cellspacing="0" border="0">
                                            <tr>
                                                <td style="background-color:#777777; padding:12px 18px;">
                                                    <a href="https://passwordreset.microsoftonline.com/" style="font-size:15px; font-family:Arial, Helvetica, sans-serif; color:#ffffff; text-decoration:none; font-weight:bold;">
                                                        Redefinir senha
                                                    </a>
                                                </td>
                                            </tr>
                                        </table>
                                    </td>
                                </tr>
                            </table>

                            <p style="margin:0 0 20px 0; font-size:16px; line-height:1.6; color:#1f1f1f;">
                                Após a alteração, aguarde alguns minutos para a sincronização da senha e utilize a nova senha nos acessos corporativos, como computador, e-mail, VPN e demais sistemas integrados à sua conta de rede.
                            </p>

                            <p style="margin:0 0 28px 0; font-size:16px; line-height:1.6; color:#1f1f1f;">
                                Caso encontre qualquer dificuldade para realizar a troca de senha, entre em contato com a equipe Microsoft.
                            </p>

                            <p style="margin:0; font-size:16px; line-height:1.6; color:#1f1f1f;">
                                Atenciosamente,<br>
                                <strong>Equipe Redix</strong>
                            </p>

                        </td>
                    </tr>

                    <tr>
                        <td style="padding:0 40px;">
                            <table width="100%" cellpadding="0" cellspacing="0" border="0">
                                <tr>
                                    <td style="border-top:1px solid #e5e5e5; font-size:1px; line-height:1px;">
                                        &nbsp;
                                    </td>
                                </tr>
                            </table>
                        </td>
                    </tr>

                    <tr>
                        <td style="padding:22px 40px 30px 40px;">
                            <p style="margin:0 0 6px 0; font-size:12px; line-height:1.5; color:#777777;">
                                Enviado por Redix
                            </p>

                            <p style="margin:0; font-size:12px; line-height:1.5; color:#777777;">
                                Esta é uma mensagem automática. Por favor, não responda este e-mail.
                            </p>
                        </td>
                    </tr>

                </table>

            </td>
        </tr>
    </table>

</body>
</html>
"@

    return $Html
}

# ============================================================
# BUSCA USUÁRIOS NO AD
# ============================================================

$Properties = @(
    "DisplayName",
    "mail",
    "UserPrincipalName",
    "PasswordLastSet",
    "PasswordNeverExpires",
    "PasswordExpired",
    "LockedOut",
    "msDS-UserPasswordExpiryTimeComputed",
    "DistinguishedName"
)

$Params = @{
    Filter     = 'Enabled -eq $true -and mail -like "*" -and PasswordNeverExpires -eq $false'
    Properties = $Properties
}

if (-not [string]::IsNullOrWhiteSpace($SearchBase)) {
    $Params.SearchBase = $SearchBase
}

$Users = @(Get-ADUser @Params | Where-Object {
    $_.LockedOut -ne $true -and
    -not [string]::IsNullOrWhiteSpace($_.mail)
})

# ============================================================
# PROCESSA E ENVIA
# ============================================================

foreach ($User in $Users) {

    $ExpiryDate = Get-PasswordExpiryDate -User $User

    if ($null -eq $ExpiryDate) {
        continue
    }

    $DaysLeft = ($ExpiryDate.Date - $Today).Days

    if ($ThresholdDays -notcontains $DaysLeft) {
        continue
    }

    $Name = if (-not [string]::IsNullOrWhiteSpace($User.DisplayName)) {
        $User.DisplayName
    }
    else {
        $User.SamAccountName
    }

    $To = $User.mail
    $Subject = "Ação necessária: sua senha expira em $DaysLeft dia(s)"
    $BodyHtml = Get-PasswordExpiryHtml -Name $Name -DaysLeft $DaysLeft -ExpiryDate $ExpiryDate

    $Message = $null
    $Client = $null

    try {
        $Message = New-Object System.Net.Mail.MailMessage
        $Message.From = $From
        $Message.To.Add($To)
        $Message.Subject = $Subject
        $Message.SubjectEncoding = [System.Text.Encoding]::UTF8
        $Message.Body = $BodyHtml
        $Message.BodyEncoding = [System.Text.Encoding]::UTF8
        $Message.IsBodyHtml = $true

        $Client = New-Object System.Net.Mail.SmtpClient($SmtpServer, $SmtpPort)
        $Client.EnableSsl = $true
        $Client.UseDefaultCredentials = $false
        $Client.Credentials = New-Object System.Net.NetworkCredential($SmtpUser, $SmtpPassword)
        $Client.Timeout = 30000

        $Client.Send($Message)
    }
    catch {
        # Sem log por solicitação.
        # Se um usuário falhar, o script continua para os próximos.
    }
    finally {
        if ($Message -ne $null) {
            $Message.Dispose()
        }

        if ($Client -ne $null) {
            $Client.Dispose()
        }
    }
}