""" Model of modular audio converter expansion board. 

This model assumes that isolation is completely transparent.
"""

from myhdl import *
from test_settings import *

from testbase import TestBase

#   This is here merely to check the type when instantiating.
from dac_pmod import DAC_PMOD

class ConverterBoard(TestBase):
    def __init__(self, *args, **kwargs):
        super(ConverterBoard, self).__init__(*args, **kwargs)
        
        #   Build list of converter objects (exception: port 0 uses PMOD-DA2)
        self.converters = []
        
    def add_module(self, converter_class, parameters):
        parameters['parent'] = self
        parameters['port_index'] = len(self.converters)
        self.converters.append(converter_class(**parameters))
        
    def myhdl_module(self, 
        #   Array of 4 6-pin bidirectional data buses.  In Verilog (and reality) this is a single bus.
        #   The direction is controlled by the direction pins on the converter cards:
        #   if the pin is held low, the FPGA drives; if the pin is high, the converter drives.
        slot_data_in, slot_data_out, 
        #   SPI buses for ADCs and DACs
        spi_adc_cs, spi_adc_mclk, spi_adc_mdi, spi_adc_mdo, 
        spi_dac_cs, spi_dac_mclk, spi_dac_mdi, spi_dac_mdo,
        #   Hardware ADC configuration
        custom_adc_hwcon, custom_adc_ovf,
        #   PMOD connectors
        pmod,
        #   Other interesting signal lines
        custom_clk0, custom_clk1, custom_dirchan, custom_srclk, custom_clksel, reset 
        ):
        
        """ Onboard signals """
        #   Chip select lines for individual DAC and ADC serial ports
        dmcs = [Signal(False) for i in range(4)]
        amcs = [Signal(False) for i in range(4)]
        
        #   Overflow bits for each of the ADC ports
        aovfl = [Signal(False) for i in range(4)]
        aovfr = [Signal(False) for i in range(4)]
        
        #   Clock select signals for each of the converter ports
        clksel = [Signal(False) for i in range(4)]
        clk = [Signal(False) for i in range(4)]
        
        #   Direction and number of channels
        direction = [Signal(False) for i in range(4)]       #   0 = DAC, 1 = ADC
        chan = [Signal(False) for i in range(4)]            #   0 = 2-ch, 1 = 8-ch
        
        #   Counter for shift register clock
        srclk_count = Signal(intbv(0)[3:])
        
        #   PMOD breakout signals
        pmod_clk = Signal(False)
        pmod_sync = Signal(False)
        pmod_dina = Signal(False)
        pmod_dinb = Signal(False)
        
        """ Clock drivers """
        #   clk0: 11.2896 MHz (controlled in test_settings)
        @always(delay(CLK0_PERIOD/2))
        def update_clk0():
            custom_clk0.next = not custom_clk0
            
        #   clk1: 24.576 MHz (controlled in test_settings)
        @always(delay(CLK1_PERIOD/2))
        def update_clk1():
            custom_clk1.next = not custom_clk1

        #   Send the appropriate clock to all converter boards
        @always_comb
        def update_converter_clocks():
            for i in range(4):
                if clksel[i] == 0:
                    clk[i].next = custom_clk0
                else:
                    clk[i].next = custom_clk1

        """ Serializer/deserializer
            Several multibit signals are converted to serial form at 
            8x the clock rate.  The bit clock is spi_dac_mclk and new values 
            are loaded at positive edges of custom_srclk (every 8 cycles).
        """
        #   Deserialize on the way in: SPI chip selects, clock selects
        @always(spi_dac_mclk.posedge)
        def deserialize():
            if reset:
                srclk_count.next = 0
                for i in range(4):
                    dmcs[i].next = False
                    amcs[i].next = False
                    clksel[i].next = False
            else:
                srclk_count.next = (srclk_count + 1) % 8
                if (srclk_count < 4):
                    dmcs[srclk_count._val._val].next = spi_dac_cs
                    amcs[srclk_count._val._val].next = spi_adc_cs
                    clksel[srclk_count._val._val].next = custom_clksel
        
        #   Serialize on the way out: ADC overflow bits, direction/channels
        @always(spi_dac_mclk.posedge)
        def serialize():
            if reset:
                custom_dirchan.next = False
                custom_adc_ovf.next = False
            else:
                if srclk_count % 2 == 0:
                    custom_adc_ovf.next = aovfl[srclk_count._val._val / 2]
                else:
                    custom_adc_ovf.next = aovfr[srclk_count._val._val / 2]
                if srclk_count < 4:
                    custom_dirchan.next = direction[srclk_count._val._val]
                else:
                    custom_dirchan.next = chan[srclk_count._val._val - 4]
        
        """ Monitoring """
        #   Break up the PMOD connection for the PMOD DAC.
        @always_comb
        def pmod_breakout():
            pmod_clk.next = pmod[3]
            pmod_dinb.next = pmod[2]
            pmod_dina.next = pmod[1]
            pmod_sync.next = pmod[0]
        
        """ Converter blocks """
        converter_instances = []
        for i in range(4):
            if i < len(self.converters):
                if isinstance(self.converters[i], DAC_PMOD):
                    converter_instances.append(self.converters[i].myhdl_module(pmod_clk, pmod_sync, pmod_dina, pmod_dinb))
                else:
                    converter_instances.append(self.converters[i].myhdl_module(slot_data_in[i], slot_data_out[i], amcs[i], spi_adc_mclk, spi_adc_mdi, spi_adc_mdo, dmcs[i], spi_dac_mclk, spi_dac_mdi, spi_dac_mdo, custom_srclk, custom_adc_hwcon, direction[i], chan[i], aovfl[i], aovfr[i], clk[i], reset))

        
        return instances()
        
