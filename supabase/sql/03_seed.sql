-- Starting accounts. Wrong or dead handles are marked "invalid" automatically after 3 failed fetches.
insert into public.accounts(platform, handle, origin, status) values
  -- X: productized studios, agency founders, designers who sell through posting
  ('x','BrettFromDJ','seed','watch'), ('x','jackbutcher','seed','watch'), ('x','theChrisDo','seed','watch'),
  ('x','michaelriddering','seed','watch'), ('x','steveschoger','seed','watch'), ('x','oguzyagizkara','seed','watch'),
  ('x','vanschneider','seed','watch'), ('x','MengTo','seed','watch'), ('x','pablostanley','seed','watch'),
  ('x','0xDesigner','seed','watch'), ('x','karrisaarinen','seed','watch'), ('x','justcreative','seed','watch'),
  ('x','logogeek','seed','watch'), ('x','jessicahische','seed','watch'), ('x','draplin','seed','watch'),
  ('x','danmall','seed','watch'), ('x','brad_frost','seed','watch'), ('x','mds','seed','watch'),
  ('x','JonYablonski','seed','watch'), ('x','Malarkey','seed','watch'), ('x','thefuturishere','seed','watch'),
  ('x','pentagram','seed','watch'), ('x','metalab','seed','watch'), ('x','ramotion','seed','watch'),
  ('x','instrument','seed','watch'), ('x','wearecollins','seed','watch'),
  -- Instagram: studios and designers who post work and process
  ('instagram','pentagramdesign','seed','watch'), ('instagram','thefuturishere','seed','watch'),
  ('instagram','wolffolins','seed','watch'), ('instagram','landor','seed','watch'),
  ('instagram','jessicawalsh','seed','watch'), ('instagram','draplin','seed','watch'),
  ('instagram','jessicahische','seed','watch'), ('instagram','ramotion','seed','watch'),
  ('instagram','wearecollins','seed','watch'), ('instagram','motherdesign','seed','watch'),
  ('instagram','kotostudio','seed','watch'), ('instagram','halolab.team','seed','watch'),
  -- Bluesky
  ('bluesky','bradfrost.com','seed','watch'), ('bluesky','danmall.com','seed','watch'),
  ('bluesky','jessicahische.is','seed','watch'), ('bluesky','zeldman.com','seed','watch'),
  ('bluesky','stuffandnonsense.co.uk','seed','watch'),
  -- YouTube (@handles; resolved to channel ids on first fetch)
  ('youtube','@thefutur','seed','watch'), ('youtube','@SatoriGraphics','seed','watch'),
  ('youtube','@WillPaterson','seed','watch'), ('youtube','@FluxAcademy','seed','watch'),
  ('youtube','@CharliMarieTV','seed','watch'), ('youtube','@DesignCourse','seed','watch'),
  ('youtube','@JesseShowalter','seed','watch'), ('youtube','@RanSegall','seed','watch')
on conflict (platform, handle) do nothing;

insert into public.sources(platform, kind, value, origin) values
  ('mastodon','hashtag','branding','seed'), ('mastodon','hashtag','graphicdesign','seed'),
  ('mastodon','hashtag','logodesign','seed'), ('mastodon','hashtag','webdesign','seed'),
  ('mastodon','hashtag','uxdesign','seed'), ('mastodon','hashtag','uidesign','seed'),
  ('mastodon','hashtag','brandidentity','seed'), ('mastodon','hashtag','typography','seed'),
  ('mastodon','hashtag','freelance','seed'), ('mastodon','hashtag','designagency','seed')
on conflict do nothing;

insert into public.topic_terms(term, pattern) values
  ('Figma', '\mfigma\M'), ('Framer', '\mframer\M'), ('Webflow', '\mwebflow\M'), ('Shopify', '\mshopify\M'),
  ('WordPress', '\mwordpress\M'), ('AI tools', '\m(ai|genai|chatgpt|claude|gemini|gpt)\M'),
  ('Midjourney', '\mmidjourney\M'), ('Vibe coding', '(vibe[- ]?cod|\mcursor\M|\mv0\M|\mlovable\M|\mbolt\.new)'),
  ('Logo design', '\mlogos?\M'), ('Rebrand', '\mrebrand'), ('Brand identity', 'brand identit|visual identit'),
  ('Brand strategy', 'brand strateg|positioning'), ('Landing page', 'landing page'), ('Website', '\mwebsites?\M'),
  ('Portfolio', '\mportfolio'), ('Case study', 'case stud'), ('Pricing', '\m(pricing|price|rates?|charge|charging)\M'),
  ('Retainer', '\mretainer'), ('Getting clients', '\mclients?\M'), ('Cold outreach', 'cold (email|outreach|dm)'),
  ('Testimonials', 'testimonial|review from'), ('Design system', 'design system'), ('Typography', 'typograph|\mfonts?\M|typeface'),
  ('Motion', '\m(motion|animation|animated)\M'), ('3D', '\m3d\M'), ('Packaging', 'packaging'), ('SaaS', '\msaas\M'),
  ('Startups', '\mstartups?\M'), ('UX audit', 'ux (audit|review)'), ('Conversion', 'conversion|\mcro\M'),
  ('SEO', '\mseo\M'), ('Personal brand', 'personal brand'), ('LinkedIn', '\mlinkedin\M'), ('Newsletter', 'newsletter'),
  ('Productized service', 'productiz|design subscription|unlimited design'), ('Freelancing', '\mfreelanc'),
  ('Agency life', '\magenc(y|ies)\M'), ('Burnout', 'burn ?out'), ('No-code', 'no-?code'),
  ('Accessibility', 'accessib|\ma11y\M'), ('Dark mode', 'dark mode'), ('Glassmorphism', 'glass(morph| effect)|liquid glass'),
  ('Bento grid', '\mbento\M'), ('Illustration', 'illustrat'), ('Mobile app', '\m(ios|android|mobile app|app design)\M'),
  ('Dashboard', '\mdashboards?\M'), ('Onboarding', 'onboarding'), ('Revenue / MRR', '\m(mrr|arr|revenue|\$\d)'),
  ('Hiring', '\m(hiring|we''re hiring|job opening)\M'), ('Process', '\m(process|behind the scenes|bts|wip)\M')
on conflict (term) do nothing;
