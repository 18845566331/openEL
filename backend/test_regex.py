import re
text = '<w:p w14:paraId="12" w:rsidR="34">'
t1 = re.sub(r'\s*w14:paraId="[^"]*"', '', text)
print(f"Original: {text}")
print(f"Replaced: {t1}")

text2 = '<w:p w14:paraId="12" w14:textId="56" w:rsidR="34">'
t2 = re.sub(r'\s*w14:paraId="[^"]*"', '', text2)
t2 = re.sub(r'\s*w14:textId="[^"]*"', '', t2)
print(f"Original: {text2}")
print(f"Replaced twice: {t2}")
