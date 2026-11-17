# Qlik Task Monitor

Qlik Sense Enterprise (on-prem) task'larını QRS API üzerinden dakikada bir kontrol eder; fail olan task'ı Microsoft Teams kanalına kart olarak bildirir.

**Bildirdikleri**
- 🔴 Task başarısız / hata / iptal (task, uygulama, stream, süre, node, hata detayı, QMC & uygulama linki)
- 🟢 Daha önce fail olan task tekrar başarılı oldu (`NotifyOnRecovery`)
- ⚠️ QRS'e üst üste N kez ulaşılamadı (izleyicinin kendisi kör kaldığında) ve bağlantı geri geldi
- Aynı turda çok sayıda fail varsa (`MaxCardsPerCycle` üstü) tek özet kart

İlk çalıştırmada mevcut durum sessizce kaydedilir; yalnızca **bundan sonraki** fail'ler bildirilir.

## Gereksinimler
- Qlik Sense sunucusunda (central node önerilir) Windows PowerShell 5.1 — ek kurulum yok
- Qlik servis hesabı (QlikClient sertifikası bu hesabın sertifika deposunda) **veya** QMC'den export edilmiş `client.pfx`
- Teams kanalında bir webhook

## Kurulum (adım adım)

> PowerShell kurmanıza **gerek yok**. Windows Server 2012 R2 ve sonrasında Windows PowerShell 5.1 hazır gelir; sadece kontrol edeceğiz.
> İlk denemeyi test sunucusunda yapın. Çalıştığı görülünce aynı adımları PROD'da tekrarlayın.
> Kurulum klasörü: **`C:\ProgramData\QlikTaskMonitor`** (ProgramData gizli bir klasör; Dosya Gezgini'nin adres çubuğuna yolu yazarak açın).

Komutlarda `SIRKET\svc_qlik` gördüğünüz yere Adım 1'de bulacağınız servis hesabını yazın.

### Adım 1 — Sunucuda ön kontroller
Sunucuya Uzak Masaüstü (RDP) ile bağlanın. Başlat → **Windows PowerShell** açın ve sırayla çalıştırın:

```powershell
$PSVersionTable.PSVersion                         # Major = 5 (Minor 1) olmalı
hostname                                          # makine adı → config'te QrsHost olacak
Test-NetConnection localhost -Port 4242           # TcpTestSucceeded : True olmalı (QRS API)
```

**Qlik servis hesabını bulun:** Başlat → `services.msc` → **Qlik Sense Repository Service** → çift tık → **Log On** sekmesi. Oradaki hesap (ör. `SIRKET\svc_qlik`) aşağıda "servis hesabı" dediğimiz hesap. Parolasını sistem yöneticisinden alın.

### Adım 2 — Teams webhook'u oluşturun (kendi bilgisayarınızda) ✅
1. Teams'te bildirimlerin düşeceği kanala gidin (ör. "Qlik Alarmlar").
2. Kanal adının yanındaki `...` → **Workflows**.
3. Arama kutusuna **webhook** yazın ve **"Send webhook alerts to a channel"** şablonunu seçin (Türkçe arayüzde *"Bir kanala web kancası uyarıları gönder"*; eski adı *"Post to a channel when a webhook request is received"*).
4. Workflow'a ad verin → bağlantının yeşil tik aldığını görün → **Next** → takım ve kanalı seçin → **Add workflow**.
5. Son ekranda verilen uzun URL'yi kopyalayın. Sonradan da bulabilirsiniz: Teams → Workflows uygulaması → ilgili workflow → *When a Teams webhook request is received* adımı. Bu URL parola gibidir, paylaşmayın.

**Şablon hiç çıkmıyorsa:**
- **Power Automate ile:** [make.powerautomate.com](https://make.powerautomate.com) → *Create* → *Instant cloud flow* → tetikleyici **"When a Teams webhook request is received"** → *Who can trigger*: **Anyone** → adım ekle: **Apply to each** (girdi: `attachments`) → içine **"Post card in a chat or channel"** (Post as: Flow bot, Post in: Channel, Adaptive Card: `content`) → kaydedince tetikleyicide URL oluşur.
- **Workflows uygulaması kapalıysa:** şirket politikası engelliyor olabilir. Kanal → `...` → *Manage channel* → *Connectors* → **Incoming Webhook** (eski yöntem; Microsoft kaldırıyor ama aynı mesaj formatını kabul eder). O da yoksa Teams yöneticisinden Workflows'un açılmasını isteyin.

### Adım 3 — Dosyalar ve klasör izni ✅ (dosyalar kopyalandı)
Dosyalar `C:\ProgramData\QlikTaskMonitor` altında olmalı: `QlikTaskMonitor.ps1`, `Install-QlikTaskMonitor.ps1`, `config.example.json`, `README.md`.

**Yönetici olarak** açılmış PowerShell'de bir kez çalıştırın:
```powershell
# Servis hesabı bu klasöre state.json ve logs\ yazabilsin
icacls "C:\ProgramData\QlikTaskMonitor" /grant "SIRKET\svc_qlik:(OI)(CI)M"

# Kopyalanan dosyalar üzerindeki Windows engelini kaldır
Get-ChildItem "C:\ProgramData\QlikTaskMonitor" | Unblock-File
```
`icacls` çıktısında `Successfully processed 1 files` görmelisiniz.

### Adım 4 — Webhook URL'sini sunucuda doğrulayın 👉 *buradasınız*
Bu adım script'ten bağımsızdır; sadece sunucunun Teams'e mesaj atabildiğini gösterir.

Normal bir PowerShell penceresinde aşağıdaki blokta `'BURAYA-URL'` kısmını Adım 2'deki URL ile değiştirin. **Tek tırnaklar kalmalı**, yoksa `&` karakterleri hata verir. Sonra bloğu olduğu gibi yapıştırıp çalıştırın:

```powershell
$url = 'BURAYA-URL'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# 1) Ağ erişimi: TcpTestSucceeded : True olmalı
Test-NetConnection ([uri]$url).Host -Port 443

# 2) Deneme mesajı
$body = '{"type":"message","attachments":[{"contentType":"application/vnd.microsoft.card.adaptive","content":{"type":"AdaptiveCard","version":"1.4","body":[{"type":"TextBlock","text":"Webhook testi: sunucudan Teams erisimi calisiyor","wrap":true}]}}]}'
Invoke-RestMethod -Uri $url -Method Post -ContentType 'application/json' -Body $body -UseBasicParsing
```

**Sonuç nasıl yorumlanır:**
| Ne gördünüz | Anlamı |
|---|---|
| Hata yok, çıktı boş ve kanala "Webhook testi..." mesajı geldi | ✅ Tamam, Adım 5'e geçin |
| `TcpTestSucceeded : False` veya `Unable to connect` / zaman aşımı | Sunucudan internete çıkış kapalı. Ağ ekibinden `*.logic.azure.com:443` (ve gerekiyorsa `*.environment.api.powerplatform.com:443`) için izin isteyin; proxy kullanılıyorsa proxy adresini öğrenin, script'e eklenir |
| `401` / `DirectApiAuthorizationRequired` | Workflow'da *Who can trigger* **Anyone** değil → workflow'u düzenleyip değiştirin |
| `400 Bad Request` | URL eksik kopyalanmış olabilir. URL `...&sig=...` ile bitmeli |
| `202` hatasız ama mesaj gelmedi | Teams → Workflows → workflow → *Run history* bölümünde hatayı kontrol edin |
| `The request was aborted: Could not create SSL/TLS secure channel` | `Tls12` satırını çalıştırmadınız; bloğu tekrar baştan çalıştırın |

### Adım 5 — config.json'ı hazırlayın
`config.example.json` dosyasını aynı klasörde `config.json` adıyla kopyalayın:
```powershell
Copy-Item "C:\ProgramData\QlikTaskMonitor\config.example.json" "C:\ProgramData\QlikTaskMonitor\config.json"
notepad "C:\ProgramData\QlikTaskMonitor\config.json"
```

Şu alanları değiştirin:

| Alan | Ne yazılacak |
|---|---|
| `EnvironmentName` | Kartlarda görünecek etiket: `TEST` veya `PROD` |
| `QrsHost` | Adım 1'deki `hostname` çıktısı |
| `TeamsWebhookUrl` | Adım 2'deki URL. İki tırnak arasına yapıştırın, satır sonundaki virgülü silmeyin |
| `QmcBaseUrl` | Tarayıcıda QMC'yi açtığınız adres, ör. `https://qliksense.sirket.local/qmc` |
| `HubBaseUrl` | Hub adresinin kökü, ör. `https://qliksense.sirket.local` |

Örnek:
```json
"TeamsWebhookUrl": "https://xxxx.logic.azure.com:443/workflows/.../invoke?api-version=1&sp=...&sv=1.0&sig=...",
```
Geri kalan alanları şimdilik olduğu gibi bırakın. Kaydedip kapatın.

### Adım 6 — Servis hesabıyla PowerShell açın
Script servis hesabının sertifikasını kullandığı için testler **o hesapla** yapılmalı:
```powershell
runas /user:SIRKET\svc_qlik powershell
```
Parola sorulur; açılan **yeni** pencerede sertifikanın orada olduğunu kontrol edin:
```powershell
Get-ChildItem Cert:\CurrentUser\My | Where-Object Subject -eq 'CN=QlikClient'
```
Bir satır dönmeli. Boşsa yanlış hesaptasınız (ya da aşağıdaki "Kimlik doğrulama seçenekleri" bölümündeki `Pfx` yöntemine geçilir).

### Adım 7 — Script ile Teams testi
Adım 6'daki pencerede:
```powershell
cd C:\ProgramData\QlikTaskMonitor
powershell -ExecutionPolicy Bypass -File .\QlikTaskMonitor.ps1 -TestNotification
```
Teams kanalına "✅ [TEST] Qlik Task Monitor test mesajı" kartı düşmeli. (Adım 4 başarılıysa bu adımdaki hata config.json kaynaklıdır.)

### Adım 8 — QRS testi
Aynı pencerede:
```powershell
powershell -ExecutionPolicy Bypass -File .\QlikTaskMonitor.ps1 -Once -Verbose
```
Beklenen çıktı: `İlk tarama tamam: N task kaydedildi ...`. Bu ilk tarama hiçbir bildirim göndermez, sadece mevcut durumu kaydeder. Klasörde `state.json` ve `logs\monitor.log` oluşmalı.

### Adım 9 — Gerçek bir fail ile uçtan uca deneme
1. Hub'da `Monitor_Test` adlı boş bir uygulama oluşturun. Data load editor'a şu tek satırı yazıp kaydedin (bilerek hata verir):
   ```
   LOAD * FROM [lib://OlmayanKlasor/yok.qvd] (qvd);
   ```
2. Adım 6'daki pencerede izleyiciyi sürekli modda başlatın (pencere açık kalsın):
   ```powershell
   powershell -ExecutionPolicy Bypass -File .\QlikTaskMonitor.ps1
   ```
3. QMC → **Tasks** → `Monitor_Test` için reload task oluşturup **Start** edin.
4. En geç ~1 dakika içinde Teams'e 🔴 kart gelmeli.
5. Script'teki satırı silip (boş script) task'ı tekrar çalıştırın → 🟢 "tekrar başarılı" kartı gelmeli.
6. Pencerede `Ctrl+C` ile durdurun. Test uygulamasını ve task'ı silebilirsiniz.

### Adım 10 — Kalıcı kurulum
Normal (servis hesabı olmayan) bir PowerShell'i **Yönetici olarak** açın:
```powershell
cd C:\ProgramData\QlikTaskMonitor
powershell -ExecutionPolicy Bypass -File .\Install-QlikTaskMonitor.ps1 -ServiceAccount 'SIRKET\svc_qlik'
```
Parola sorulduğunda servis hesabının parolasını girin.

### Adım 11 — Çalıştığını doğrulayın
- Başlat → `taskschd.msc` → **Qlik Task Monitor** görevi → Durum: *Running*.
- `C:\ProgramData\QlikTaskMonitor\logs\monitor.log` dosyasında `Başladı. QRS: ...` satırı olmalı.
- Sunucu yeniden başlatıldığında görev kendiliğinden başlar.

Kaldırmak için (Yönetici PowerShell):
```powershell
cd C:\ProgramData\QlikTaskMonitor
powershell -ExecutionPolicy Bypass -File .\Install-QlikTaskMonitor.ps1 -Uninstall
```

### Sık karşılaşılan hatalar
| Log / ekrandaki hata | Sebep → Çözüm |
|---|---|
| `The ampersand (&) character is not allowed` | URL tırnaksız yazılmış → tek tırnak içine alın veya sadece config.json'a koyun |
| `Config bulunamadı` | `config.json` oluşturulmamış veya yanlış klasördesiniz → Adım 5, `cd` komutu |
| `Sertifika bulunamadı` | Script servis hesabıyla çalışmıyor → Adım 6 |
| `Access to the path ... is denied` (state.json / logs) | Servis hesabının klasöre yazma izni yok → Adım 3 `icacls` |
| `Unable to connect` / zaman aşımı (QRS) | `QrsHost` yanlış veya 4242 kapalı → Adım 1 |
| `403 Forbidden` (QRS) | `X-Qlik-User` kullanıcısının yetkisi yok → `sa_repository` kalsın |
| `Teams gönderilemedi` / zaman aşımı | Sunucudan internete çıkış yok → Adım 4 |
| `running scripts is disabled` | Komutu `powershell -ExecutionPolicy Bypass -File ...` ile çalıştırın |
| config.json'da `Invalid JSON primitive` / `ConvertFrom-Json` hatası | Tırnak veya virgül eksik → Notepad'de URL satırını kontrol edin |

## Kimlik doğrulama seçenekleri
| `Auth.Mode` | Ne zaman |
|---|---|
| `CertStore` (varsayılan) | Script Qlik servis hesabıyla çalışıyor; `Cert:\CurrentUser\My` altındaki `CN=QlikClient` kullanılır |
| `Pfx` | Başka hesapla/başka makinede çalışacaksa. QMC → Certificates → Export (Platform independent PEM değil, **Windows format**, private key dahil). Parola `QLIK_MONITOR_PFX_PASSWORD` ortam değişkeninde tutulabilir |

`UserDirectory=INTERNAL; UserId=sa_repository` QRS'e tam okuma yetkisi verir. Daha kısıtlı bir kullanıcı isterseniz task ve app okuma yetkisi olan bir kullanıcı yazın.

`SkipServerCertValidation: true` — Qlik'in kendi imzaladığı sunucu sertifikası, sunucu adı eşleşmediğinde hata verir; ortam izole olduğu için varsayılan olarak açık. Qlik root CA'sı güvenilirse ve `QrsHost` sertifikadaki adla aynıysa `false` yapın.

## Ayarlar
| Alan | Varsayılan | Açıklama |
|---|---|---|
| `PollIntervalSeconds` | 60 | Kontrol sıklığı |
| `FailStatuses` | `[6, 8, 11]` | Bildirilecek durumlar: 6 İptal edildi, 8 Başarısız, 11 Hata. Atlananları da isterseniz `9` ekleyin |
| `NotifyOnRecovery` | true | Fail sonrası ilk başarılı çalışmada yeşil kart |
| `AlertExistingFailuresOnStart` | false | İlk açılışta zaten fail durumdaki task'ları da bildir |
| `ConnectionFailureThreshold` | 3 | Kaç ardışık QRS hatasından sonra "izlenemiyor" uyarısı |
| `MaxCardsPerCycle` | 5 | Bir turda bundan fazla fail varsa tek özet kart |
| `IncludeExternalProgramTasks` | true | External program task'larını da izle |
| `TaskNameInclude` / `TaskNameExclude` | boş | Task adına regex filtresi, ör. `"^PROD_"` / `"TEST|DENEME"` |

## Dosyalar
- `state.json` — hangi çalışmaların bildirildiğini tutar (silerseniz veya `-ResetState` ile ilk tarama tekrar yapılır)
- `logs\monitor.log` — 10 MB'ı geçince `.old` olarak döner

## Sınırlar
- Her task'ın **son** çalışmasına bakar. Bir task iki kontrol arasında (60 sn) hem fail olup hem başarıyla yeniden çalışırsa o fail görülmez; pratikte reload süreleri bunun çok altında kalmaz.
- Script log içeriği karta eklenmez; hata mesajı QRS'in `details` alanından gelir. Tam log için QMC'deki task → *Download script log*.
