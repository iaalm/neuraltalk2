import json
import sys

with open(sys.argv[1],'r') as fd:
    data = json.load(fd)
tmp = data.pop('sentences')
for i in tmp:
    i['image_id'] = int(i['video_id'][5:])
data['annotations'] = tmp
for i in tmp:
    i['id'] = i['sen_id']
tmp = data.pop('videos')
data['images'] = tmp
data['type'] = "captions"
data['licenses'] = []

with open(sys.argv[2],'w') as fd:
    json.dump(data,fd)

