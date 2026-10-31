-- Vereine werden nicht mehr geprueft: Wer sich als Verein registriert, ist
-- sofort bestaetigt. Website und Ort bleiben Pflicht.
-- Vereine aendern ihre Website selbst, Snapchat gibt es bei ihnen nicht.
do $$
declare d text; alt text; neu text;
begin
  d := pg_get_functiondef('public.handle_new_user'::regproc);
  alt := E'      v_dom := lower(split_part(new.email,''@'',2));\n      if ist_freimail(v_dom) or not domain_passt(new.email, v_web) then\n        v_stat := ''handpruefung'';\n      else\n        v_stat := ''neu'';\n      end if;';
  neu := E'      v_stat := ''bestaetigt'';';
  if position(alt in d) = 0 then raise exception 'handle_new_user: Stelle nicht gefunden'; end if;
  execute replace(d, alt, neu);

  d := pg_get_functiondef('public.guard_pro_columns'::regproc);
  alt := E'  new.website                         := old.website;\n';
  if position(alt in d) = 0 then raise exception 'guard: Website nicht gefunden'; end if;
  d := replace(d, alt, '');
  alt := E'  -- Geburtsdatum: einmal gesetzt, bleibt es; unter 16 geht nicht\n';
  neu := E'  -- Nur Vereine haben eine Website, leer werden darf sie nicht. Snapchat gibt es bei ihnen nicht.\n'
      || E'  if coalesce(old.kontoart,''privat'') <> ''verein'' or nullif(trim(coalesce(new.website,'''')),'''') is null then\n'
      || E'    new.website := old.website;\n'
      || E'  end if;\n'
      || E'  if old.kontoart = ''verein'' then\n'
      || E'    new.snapchat_handle := null;\n'
      || E'  end if;\n\n'
      || alt;
  if position(alt in d) = 0 then raise exception 'guard: Geburtsdatum nicht gefunden'; end if;
  execute replace(d, alt, neu);
end $$;
