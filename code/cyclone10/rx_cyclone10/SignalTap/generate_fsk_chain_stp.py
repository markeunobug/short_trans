from pathlib import Path
import copy, re, xml.etree.ElementTree as E
base=Path(__file__).resolve().parents[1]
template=E.parse(base/'stp1.stp').getroot()
def sig(name,width=1,radix='hexadecimal',source=None,source_lsb=0):
 return (name,width,radix,source or name,source_lsb)
groups=[
('samples',1024,'demod_sample_valid',[sig('demod_sample_valid'),sig('sample_fifo_rd_valid'),sig('sample_fifo_rd_data',32,'line_signed'),sig('demod_sample_data',20,'line_signed'),sig('sample_shift',5),*[sig(n) for n in ['sample_clipped_positive','sample_clipped_negative','adc_near_full_scale','adc_stream_valid','adc_config_valid','mclk_present','sweep_active','rst_fsk_n','sample_overflow_sync_ff2','i2s_error_sync_ff2']]]),
('metrics',1024,'metric_valid',[sig('metric_valid'),sig('energy_f0',32),sig('energy_f1',32),sig('soft_metric',33,'line_signed'),sig('total_energy',33),sig('confidence',8),sig('confidence_threshold',8),sig('noise_energy',33),sig('carrier_threshold',33),sig('energy_margin',8),sig('noise_offset',16),*[sig(n) for n in ['hard_bit','confidence_ok','energy_above_threshold','noise_ready','carrier_active','symbol_locked']],sig('selected_phase',4)]),
('symbols',1024,'signaltap_symbol_valid',[
 sig('bit_valid',source='signaltap_symbol_valid'),
 sig('bit_value',source='signaltap_symbol_debug',source_lsb=0),
 sig('symbol_energy',33,source='signaltap_symbol_debug',source_lsb=1),
 sig('symbol_confidence',8,source='signaltap_symbol_debug',source_lsb=34),
 sig('selected_phase',4,source='signaltap_symbol_debug',source_lsb=42),
 sig('timing_adjust',2,'line_signed',source='signaltap_symbol_debug',source_lsb=46),
 sig('symbol_locked',source='signaltap_symbol_debug',source_lsb=48),
 sig('carrier_active',source='signaltap_symbol_debug',source_lsb=49),
 sig('frame_parser_busy',source='signaltap_symbol_debug',source_lsb=50)
]),
('frames',512,None,[*[sig(n) for n in ['frame_valid','frame_payload_valid','frame_payload_last']],sig('frame_payload_data',8),sig('frame_payload_length',8),sig('frame_version_type',8),sig('frame_sequence',8),sig('frame_timestamp',32),*[sig(n) for n in ['frame_timestamp_valid','frame_is_time_base','header_error','length_error','crc_error','frame_timeout_error','sync_found','frame_parser_busy','bit_valid','bit_value','preamble_detected','symbol_locked','symbol_lock_lost','symbol_search_timeout','carrier_active']]])]
rtl=(base/'rx_cyclone10.v').read_text()
root=E.Element('session',dict(template.attrib))
root.set('sof_file','../output_files/rx_cyclone10.sof')
display=E.SubElement(root,'display_tree',gui_logging_enabled='0')
raw_bits=0
for ix,(label,depth,qual,signals) in enumerate(groups):
 name=f'auto_signaltap_{ix}'
 E.SubElement(display,'display_branch',instance=name,log='USE_GLOBAL_TEMP',signal_set='USE_GLOBAL_TEMP',trigger='USE_GLOBAL_TEMP')
 inst=E.SubElement(root,'instance',enabled='true',entity_name='sld_signaltap',is_auto_node='yes',is_expanded='true',name=name,source_file='sld_signaltap.vhd')
 E.SubElement(inst,'node_ip_info',instance_id=str(ix),mfg_id='110',node_id=str(ix),version='6')
 ss=E.SubElement(inst,'signal_set',global_temp='1',is_expanded='true',name='signal_set: '+label)
 E.SubElement(ss,'clock',name='FPGA_CLK',polarity='posedge',tap_mode='probeonly')
 cfg=copy.deepcopy(template.find('instance/signal_set/config')); cfg.set('sample_depth',str(depth)); ss.append(cfg)
 E.SubElement(ss,'top_entity')
 sv=E.SubElement(ss,'signal_vec')
 tr=E.SubElement(sv,'trigger_input_vec'); data=E.SubElement(sv,'data_input_vec'); storage=E.SubElement(sv,'storage_qualifier_input_vec')
 trigger_names=[qual] if qual else ['frame_valid','header_error','length_error','crc_error','frame_timeout_error','sync_found','preamble_detected','symbol_lock_lost','symbol_search_timeout']
 for n in trigger_names: E.SubElement(tr,'wire',name=n,tap_mode='classic')
 pres=E.SubElement(ss,'presentation')
 views=[(E.SubElement(pres,n),leaf,bus) for n,leaf,bus in [('unified_setup_data_view','node','node'),('data_view','net','bus'),('setup_view','net','bus')]]
 # Quartus derives the single PORT storage_enable connection from the last
 # storage-qualifier vector entry. Keep the intended qualifier last so the
 # generated QSF connects demod_sample_valid/metric_valid/bit_valid.
 ordered_signals = [x for x in signals if x[3] != qual] + [x for x in signals if x[3] == qual]
 index=0
 for n,w,radix,source,source_lsb in ordered_signals:
  match=re.search(r'\b(?:wire|reg)\s+(?:signed\s+)?(?:\[(\d+):0\]\s+)?'+re.escape(source)+r'\b',rtl)
  source_width=(int(match[1])+1 if match and match[1] else 1)
  assert match and source_lsb+w <= source_width,(n,w,source,source_lsb,source_width)
  parents=[]
  for view,leaf,bus in views:
   if w>1 or source != n:
    display_name=(f'{n}[{w-1}..0]' if w>1 else n)
    attrs=dict(is_selected='false',name=display_name,order='msb_to_lsb',radix=radix,state='collapse',type='combinatorial')
    attrs.update({'level-0':'alt_or',**{f'storage-{j}':'alt_or' for j in range(3)}})
    parents.append((E.SubElement(view,bus,attrs),leaf))
   else: parents.append((view,leaf))
  for bit in (range(w-1,-1,-1) if w>1 else [None]):
   source_bit=source_lsb+(bit if bit is not None else 0)
   bn=(f'{source}[{source_bit}]' if source_width>1 else source)
   E.SubElement(data,'wire',name=bn,tap_mode='classic'); E.SubElement(storage,'wire',name=bn,tap_mode='classic')
   is_trigger=(source in trigger_names)
   attrs=dict(data_index=str(index),duplicate_name_allowed='false',is_data_input='true',is_node_valid='true',is_selected='false',is_storage_input='true',is_trigger_input=str(is_trigger).lower(),name=bn,storage_index=str(index),tap_mode='classic',type='unknown')
   for j in range(3): attrs.update({f'pwr_storage-{j}':'dont_care',f'storage-{j}':'dont_care'})
   if is_trigger: attrs.update({'trigger_index':str(trigger_names.index(source)),'level-0':'rising edge' if source==trigger_names[0] else 'dont_care','pwr_level-0':'dont_care'})
   for parent,leaf in parents: E.SubElement(parent,leaf,attrs)
   index+=1
 E.SubElement(pres,'trigger_in_editor'); E.SubElement(pres,'trigger_out_editor')
 trig=copy.deepcopy(template.find('instance/signal_set/trigger'))
 for child in list(trig): trig.remove(child)
 trig.attrib.pop('CRC',None)
 trig.set('name','trigger: '+label); trig.set('storage_qualifier_disabled','no' if qual else 'yes'); trig.set('storage_qualifier_port_name',qual or 'frame_valid'); trig.set('storage_qualifier_port_tap_mode','classic'); trig.set('storage_qualifier_port_is_pin','false')
 E.SubElement(trig,'power_up_trigger',position='pre',storage_qualifier_disabled='no' if qual else 'yes')
 ev=E.SubElement(trig,'events',use_custom_flow_control='no'); lv=E.SubElement(ev,'level',enabled='yes',name='condition1',type='basic'); lv.text=f"'{trigger_names[0]}' == rising edge"
 E.SubElement(lv,'power_up',enabled='yes'); E.SubElement(lv,'op_node')
 se=E.SubElement(trig,'storage_qualifier_events'); trans=E.SubElement(se,'transitional'); trans.text='1'*index; E.SubElement(trans,'pwr_up_transitional').text='1'*index
 for j in range(3):
  lv=E.SubElement(se,'storage_qualifier_level',type='basic'); E.SubElement(lv,'power_up'); E.SubElement(lv,'op_node')
 ss.append(trig)
 raw_bits+=index*depth
 print(f'{name} {label}: {index} bits x {depth}, qualifier={qual}, trigger={trigger_names[0]}')
for tag in ['mnemonics','static_plugin_mnemonics','global_info']: root.append(copy.deepcopy(template.find(tag)))
E.indent(root,space='  ')
output=base/'SignalTap'/'FSK_CHAIN_DEBUG.stp'
E.ElementTree(root).write(output,encoding='UTF-8',xml_declaration=True)
check=E.parse(output).getroot()
assert len(check.findall('instance'))==4 and not check.findall('.//log')
for inst in check.findall('instance'):
 ss=inst.find('signal_set'); names=[w.get('name') for w in ss.findall('signal_vec/data_input_vec/wire')]
 assert len(names)==len(set(names))
 for view in ['unified_setup_data_view','data_view','setup_view']:
  leaves=[e for e in ss.find('presentation/'+view).iter() if e.get('data_index') is not None]
  assert len(leaves)==len(names)
  assert all(names[int(e.get('data_index'))]==e.get('name') for e in leaves)
print(f'XML, RTL widths, index mapping passed. Raw capture bits={raw_bits}. Not a fitted RAM estimate.')

# Quartus Prime Lite 22.1 in this workspace fails while elaborating its debug
# hub when more than one SignalTap instance is enabled.  Emit one-instance
# presets as the buildable artifacts; keep the combined file for inspection.
preset_names = {
 'samples': 'FSK_1_SAMPLES_20BIT.stp',
 'metrics': 'FSK_2_DEMOD_METRICS.stp',
 'symbols': 'FSK_3_SYMBOLS.stp',
 'frames': 'FSK_4_FRAME_RESULT.stp',
}
for instance in root.findall('instance'):
 label = instance.find('signal_set').get('name').split(':', 1)[1].strip()
 preset = copy.deepcopy(root)
 for other in list(preset.findall('instance')):
  if other.get('name') != instance.get('name'):
   preset.remove(other)
 kept = preset.find('instance')
 old_name = kept.get('name')
 kept.set('name', 'auto_signaltap_0')
 node_info = kept.find('node_ip_info')
 node_info.set('instance_id', '0')
 node_info.set('node_id', '0')
 for branch in list(preset.find('display_tree')):
  if branch.get('instance') != old_name:
   preset.find('display_tree').remove(branch)
  else:
   branch.set('instance', 'auto_signaltap_0')
 E.indent(preset, space='  ')
 preset_path = base/'SignalTap'/preset_names[label]
 E.ElementTree(preset).write(preset_path, encoding='UTF-8', xml_declaration=True)
 assert len(E.parse(preset_path).getroot().findall('instance')) == 1
 print(f'Wrote buildable single-instance preset: {preset_path.name}')

